// Task 0684 — a MIRRORED layer must export with outward-facing polygons.
//
// A negative `ItemXform.scl` component is a legal item transform: the
// degenerate-scale band (`MIN_ITEM_SCALE_MAG`, document.d) clamps MAGNITUDE and
// explicitly preserves the sign, "a negative scale is a legitimate mirror", and
// `ModelSpace.mirrored` exists so picking can account for one. Every interchange
// export BAKES that matrix into the written points — and baking a
// negative-determinant matrix moves the points while leaving the face index
// order alone, so the exported surface is wound INWARD. Nothing downstream
// recovers from that: our own importer bakes node transforms with no winding
// term either (verified while writing this test — there is no compensation to
// double up on).
//
// Three export paths carry the same bake and therefore the same defect:
//
//   * `io/scene_ir.d`     `flattenDocument`      — reached by .fbx (the FBX
//                                                  writer stays on the single
//                                                  flattened-mesh path)
//   * `io/lwo_export.d`   `exportLwoDocument`    — reached by .lwo
//   * `io/scene_export.d` `buildDocumentScene`   — reached by .obj / .gltf,
//                                                  both the N==1 root-mesh
//                                                  shape and the N>=2
//                                                  child-node-per-layer shape
//
// So the single-layer sweep below covers all three modules and the two-layer
// sweep adds the child-node shape on top.
//
// THE ASSERTION is geometric, not index-order: for every face of the reloaded
// mesh, the Newell normal must point AWAY from the mesh centroid. A cube is
// convex and centred on its own centroid, so "outward" is unambiguous — and it
// is the property a user actually loses when this breaks (the model renders
// inside-out in the receiving application).
//
// FIXTURE NOTE: the mirrored layer also carries a translation, so the bake is
// OBSERVABLE. A cube mirrored about its own centre is the same point set, so a
// regression that dropped the xform bake entirely would leave a symmetric
// fixture all-outward and this test green for the wrong reason. With
// `pos.x = 2, scl.x = -1` the reloaded centroid must land at x = +2; that
// assertion is what keeps the winding check honest.
//
// The document is built by saving a `.v3d` and editing its item channels — the
// same technique tests/test_layer_xform_io.d uses, because there is no HTTP
// surface that sets a layer transform.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.file : remove, exists, readText, write;
import std.conv : to;
import std.format : format;
import std.math : fabs;
import std.process : thisProcessID;

void main() {}

// ---------------------------------------------------------------------------
// plumbing
// ---------------------------------------------------------------------------

void resetCube() {
    post(testBaseUrl() ~ "/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = cast(string) post(testBaseUrl() ~ "/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", id ~ " failed: " ~ resp);
}

void fileSave(string path) { runCmd("file.save", `{"path":"` ~ path ~ `"}`); }
void fileLoad(string path) { runCmd("file.load", `{"path":"` ~ path ~ `"}`); }

JSONValue model(long layer = -1) {
    const url = layer < 0
        ? testBaseUrl() ~ "/api/model"
        : testBaseUrl() ~ "/api/model?layer=" ~ layer.to!string;
    return parseJSON(get(url));
}

JSONValue layerList() {
    return parseJSON(get(testBaseUrl() ~ "/api/layers"));
}

/// Unique per test process (the runner runs up to 8 in parallel) AND per stem,
/// so no two cases can collide on a path.
string tmp(string stem, string ext) {
    return format("/tmp/vibe3d-0684-%s-%d%s", stem, thisProcessID, ext);
}

double comp(const JSONValue v) {
    return v.type == JSONType.integer  ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : v.floating;
}

// ---------------------------------------------------------------------------
// geometry: Newell normal vs the mesh centroid
// ---------------------------------------------------------------------------

struct V3 { double x = 0, y = 0, z = 0; }

V3[] verticesOf(const JSONValue m) {
    V3[] out_;
    foreach (v; m["vertices"].array)
        out_ ~= V3(comp(v[0]), comp(v[1]), comp(v[2]));
    return out_;
}

V3 centroid(const V3[] vs) {
    V3 c;
    foreach (v; vs) { c.x += v.x; c.y += v.y; c.z += v.z; }
    const n = cast(double) vs.length;
    return V3(c.x / n, c.y / n, c.z / n);
}

/// How many faces of `m` point AWAY from the mesh centroid, and how many point
/// into it. A correctly wound closed convex mesh is (faceCount, 0).
size_t[2] outwardInward(const JSONValue m) {
    auto vs = verticesOf(m);
    const c  = centroid(vs);
    size_t outward = 0, inward = 0;
    foreach (f; m["faces"].array) {
        auto idx = f.array;
        V3 n;
        V3 fc;
        foreach (k; 0 .. idx.length) {
            const a = vs[cast(size_t) idx[k].integer];
            const b = vs[cast(size_t) idx[(k + 1) % idx.length].integer];
            n.x += (a.y - b.y) * (a.z + b.z);
            n.y += (a.z - b.z) * (a.x + b.x);
            n.z += (a.x - b.x) * (a.y + b.y);
            fc.x += a.x; fc.y += a.y; fc.z += a.z;
        }
        const nk = cast(double) idx.length;
        const d = V3(fc.x / nk - c.x, fc.y / nk - c.y, fc.z / nk - c.z);
        if (n.x * d.x + n.y * d.y + n.z * d.z > 0) outward++; else inward++;
    }
    return [outward, inward];
}

void assertAllOutward(const JSONValue m, string ctx) {
    const oi = outwardInward(m);
    assert(m["faces"].array.length > 0, ctx ~ ": reloaded mesh has no faces");
    assert(oi[1] == 0,
        format("%s: %d of %d faces are wound INWARD after export+reload "
             ~ "(a mirrored layer must export with reversed winding)",
               ctx, oi[1], oi[0] + oi[1]));
}

// ---------------------------------------------------------------------------
// fixtures: a `.v3d` whose item channels carry the mirror
// ---------------------------------------------------------------------------

/// Save the current (reset) document as `.v3d` and return its parsed JSON.
JSONValue baseDoc(string stem) {
    resetCube();
    const p = tmp(stem ~ "-base", ".v3d");
    fileSave(p);
    auto j = parseJSON(readText(p));
    remove(p);
    return j;
}

/// One layer, mirrored on X and translated to +2 so the bake is observable.
string mirroredSingleLayerDoc(string stem) {
    auto doc = baseDoc(stem);
    doc["layers"].array[0]["channels"]["scl.x"] = JSONValue(-1.0);
    doc["layers"].array[0]["channels"]["pos.x"] = JSONValue(2.0);
    doc["layers"].array[0]["channels"]["name"]  = JSONValue("Mirror");
    const p = tmp(stem, ".v3d");
    write(p, doc.toString());
    return p;
}

/// Two layers: "Plain" at x = +3 (identity orientation) and "Mirror" at x = -3
/// with `scl.x = -1`. The two are separable by the sign of their centroid, in
/// every format, whether or not layer names survive.
string mirroredTwoLayerDoc(string stem) {
    auto doc = baseDoc(stem);
    auto l0 = doc["layers"].array[0];
    auto l1 = parseJSON(l0.toString());          // deep copy
    l0["channels"]["name"]  = JSONValue("Plain");
    l0["channels"]["pos.x"] = JSONValue(3.0);
    l1["channels"]["name"]  = JSONValue("Mirror");
    l1["channels"]["pos.x"] = JSONValue(-3.0);
    l1["channels"]["scl.x"] = JSONValue(-1.0);
    l1["selected"] = JSONValue(false);
    doc["layers"] = JSONValue([l0, l1]);
    const p = tmp(stem, ".v3d");
    write(p, doc.toString());
    return p;
}

/// Delete an exported file AND the sidecars assimp writes next to it — `.bin`
/// for glTF, `.mtl` for OBJ. Removing only the named file leaves those behind in
/// /tmp on every suite run.
void cleanExport(string path) {
    import std.path : stripExtension;
    if (exists(path)) remove(path);
    foreach (side; [".bin", ".mtl"]) {
        const s = stripExtension(path) ~ side;
        if (exists(s)) remove(s);
    }
}

/// Load `src`, export to `out_`, then RESET (so the reload cannot inherit the
/// source document's own transform) and load the export back.
void roundTrip(string src, string out_) {
    fileLoad(src);
    fileSave(out_);
    assert(exists(out_), "export produced no file: " ~ out_);
    resetCube();
    fileLoad(out_);
}

// ---------------------------------------------------------------------------
// 1. single mirrored layer -> every export path
// ---------------------------------------------------------------------------

unittest {
    // .fbx  -> flattenDocument (io/scene_ir.d)
    // .lwo  -> exportLwoDocument (io/lwo_export.d)
    // .obj/.gltf -> buildDocumentScene N==1 (io/scene_export.d)
    static immutable string[4] exts = [".fbx", ".lwo", ".obj", ".gltf"];
    const src = mirroredSingleLayerDoc("single");

    foreach (ext; exts) {
        const dst = tmp("single-rt", ext);
        roundTrip(src, dst);

        auto m = model();
        assertAllOutward(m, "mirrored single layer -> " ~ ext);

        // The bake witness: `pos.x = 2` must have landed, or the winding check
        // above would be passing on an un-baked (and therefore un-mirrored)
        // cube. FBX round-trips through a cm unit normalisation, so this also
        // pins that the two scale factors still cancel.
        const c = centroid(verticesOf(m));
        assert(fabs(c.x - 2.0) < 1e-4,
            format("%s: mirrored layer's bake did not land (centroid.x = %s, "
                 ~ "expected 2.0) — the winding assertion above is vacuous "
                 ~ "without it", ext, c.x));

        cleanExport(dst);
    }
    remove(src);
}

// ---------------------------------------------------------------------------
// 2. the control: an UNMIRRORED layer must be unaffected
// ---------------------------------------------------------------------------

unittest {
    // Same flow, `scl.x = +1`. This is what makes the case above meaningful: a
    // fix that reversed EVERY face on export would pass test 1 and fail here.
    auto doc = baseDoc("plain");
    doc["layers"].array[0]["channels"]["pos.x"] = JSONValue(2.0);
    const src = tmp("plain", ".v3d");
    write(src, doc.toString());

    static immutable string[4] exts = [".fbx", ".lwo", ".obj", ".gltf"];
    foreach (ext; exts) {
        const dst = tmp("plain-rt", ext);
        roundTrip(src, dst);
        assertAllOutward(model(), "unmirrored layer -> " ~ ext);
        cleanExport(dst);
    }
    remove(src);
}

// ---------------------------------------------------------------------------
// 3. two layers, one mirrored -> the multi-layer (child-node / multi-LAYR)
//    shapes, where the mirror rides a per-layer transform
// ---------------------------------------------------------------------------

unittest {
    // .obj / .gltf take the N>=2 child-node path in io/scene_export.d; .lwo
    // takes the per-LAYR path in io/lwo_export.d. (.fbx is deliberately routed
    // through the single flattened mesh by commands/file/save.d, so the
    // multi-layer case does not exist for it — case 1 covers its path.)
    static immutable string[3] exts = [".obj", ".gltf", ".lwo"];
    const src = mirroredTwoLayerDoc("two");

    foreach (ext; exts) {
        const dst = tmp("two-rt", ext);
        roundTrip(src, dst);

        auto ls = layerList()["layers"].array;
        assert(ls.length == 2,
            format("%s: expected 2 layers after reload, got %d", ext, ls.length));

        bool sawMirrored = false, sawPlain = false;
        foreach (l; ls) {
            const idx = l["index"].integer;
            auto m = model(idx);
            const c = centroid(verticesOf(m));
            // The mirrored layer is the one that baked to x = -3.
            const isMirrored = c.x < 0;
            if (isMirrored) sawMirrored = true; else sawPlain = true;
            assertAllOutward(m, format("%s layer %d (%s)", ext, idx,
                isMirrored ? "mirrored" : "plain"));
        }
        assert(sawMirrored && sawPlain,
            ext ~ ": both the mirrored and the plain layer must survive the "
                ~ "round trip (they are separated by centroid sign)");

        cleanExport(dst);
    }
    remove(src);
}
