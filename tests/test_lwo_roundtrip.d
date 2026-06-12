// Tests for the LWO export → import round-trip via /api/command.
//
// Phase 2 of the asset-io plan routes `.lwo` save through the lwo2-writer
// library (io.lwo_export.exportLwo); import still uses our own reader
// (lwo.importLWO). This test confirms the two halves agree end to end.
//
// Flow:
//   reset → mark every face subpatch → save to /tmp/x.lwo (lwo2-writer)
//   → mutate state (subdivide) → load /tmp/x.lwo (importLWO)
//   → /api/model topology + face index lists + subpatch flags + surface names
//   match the original cube exactly.

import std.net.curl;
import std.json;
import std.file : remove, exists, getSize;
import std.conv : to;
import std.math : abs;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post("http://localhost:8080/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// /api/model emits surface floats via printf %f, so they always decode as
// JSONType.float_; this stays robust if a whole-number value (e.g. opacity
// 1.0) ever serialises as an integer.
double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}

unittest { // export → import round-trip preserves geometry, subpatch and surfaces
    enum string path = "/tmp/vibe3d-test-lwo-roundtrip.lwo";
    if (exists(path)) remove(path);

    resetCube();

    // Mark every face as subpatch so the round-trip carries a non-trivial PTCH
    // flag array. With no face selection mesh.subpatch_toggle inverts the flag
    // on every face (all false → all true on a fresh cube).
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    runCmd("mesh.subpatch_toggle");

    auto orig = model();
    long origV = orig["vertexCount"].integer;
    long origE = orig["edgeCount"].integer;
    long origF = orig["faceCount"].integer;
    assert(origV == 8 && origE == 12 && origF == 6, "cube prerequisite");

    auto origFaces    = orig["faces"];
    auto origVertices = orig["vertices"];
    auto origSubpatch = orig["isSubpatch"];
    auto origSurfaces = orig["surfaces"];
    // Every face should now be a subpatch.
    foreach (b; origSubpatch.array)
        assert(b.type == JSONType.true_, "expected all faces subpatch after toggle");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved LWO file is empty");

    // Mutate the scene so stale state can't masquerade as a successful load.
    runCmd("mesh.subdivide");
    auto mutated = model();
    assert(mutated["vertexCount"].integer == 26,
        "subdivide should leave 26 verts before reload");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto reloaded = model();

    // Topology counts.
    assert(reloaded["vertexCount"].integer == origV,
        "reload vertexCount mismatch: expected "
        ~ origV.to!string ~ ", got "
        ~ reloaded["vertexCount"].integer.to!string);
    assert(reloaded["edgeCount"].integer == origE, "reload edgeCount mismatch");
    assert(reloaded["faceCount"].integer == origF, "reload faceCount mismatch");

    // Exact vertex positions. The exporter writes float32 verbatim and our
    // reader reads float32 verbatim, so the cube's integral ±1 coords survive
    // bit-exactly through the round-trip.
    assert(reloaded["vertices"].array.length == origVertices.array.length,
        "reload vertex array length mismatch");
    foreach (i, v; reloaded["vertices"].array) {
        auto o = origVertices.array[i].array;
        auto r = v.array;
        foreach (k; 0 .. 3)
            assert(r[k].floating == o[k].floating,
                "vertex " ~ i.to!string ~ " component " ~ k.to!string
                ~ " mismatch after round-trip");
    }

    // Exact face vertex-index lists (order + arity preserved).
    assert(reloaded["faces"].array.length == origFaces.array.length,
        "reload face array length mismatch");
    foreach (i, f; reloaded["faces"].array) {
        auto o = origFaces.array[i].array;
        auto r = f.array;
        assert(r.length == o.length,
            "face " ~ i.to!string ~ " arity mismatch after round-trip");
        foreach (k; 0 .. r.length)
            assert(r[k].integer == o[k].integer,
                "face " ~ i.to!string ~ " index " ~ k.to!string ~ " mismatch");
    }

    // Subpatch (PTCH) flags survive.
    assert(reloaded["isSubpatch"].array.length == origSubpatch.array.length,
        "reload subpatch array length mismatch");
    foreach (i, b; reloaded["isSubpatch"].array)
        assert(b.type == origSubpatch.array[i].type,
            "subpatch flag " ~ i.to!string ~ " mismatch after round-trip");

    // Surfaces survive (count + names; the default cube ships at least one).
    assert(reloaded["surfaces"].array.length == origSurfaces.array.length,
        "reload surface count mismatch");
    foreach (i, s; reloaded["surfaces"].array)
        assert(s["name"].str == origSurfaces.array[i]["name"].str,
            "surface " ~ i.to!string ~ " name mismatch after round-trip");

    // Surface VALUE path survives. No HTTP/command surface-setter exists, so we
    // can't dial in non-default values; instead we capture whatever /api/model
    // reports per surface BEFORE the save and assert the post-load values match
    // exactly. This locks the COLR / DIFF / SPEC / GLOS chunks and — critically
    // — the TRAN<->opacity double inversion (writer emits TRAN=1-opacity, reader
    // reads opacity=1-TRAN): a regression that drops the inversion or a COLR
    // write would corrupt these and fail here, where the count/name checks above
    // would still pass. Values pass through float32 + the inversion arithmetic,
    // so compare with a small epsilon rather than bit-exactly.
    enum double EPS = 1e-4;
    foreach (i, s; reloaded["surfaces"].array) {
        auto o = origSurfaces.array[i];
        // baseColor (LWO COLR), 3 components.
        auto oc = o["baseColor"].array;
        auto rc = s["baseColor"].array;
        assert(rc.length == oc.length && rc.length == 3,
            "surface " ~ i.to!string ~ " baseColor arity mismatch");
        foreach (k; 0 .. 3)
            assert(abs(num(rc[k]) - num(oc[k])) < EPS,
                "surface " ~ i.to!string ~ " baseColor[" ~ k.to!string
                ~ "] mismatch: expected " ~ num(oc[k]).to!string
                ~ ", got " ~ num(rc[k]).to!string);
        // Scalar surface channels: diffuse (DIFF), specular (SPEC),
        // glossiness (GLOS), opacity (1 - TRAN).
        foreach (field; ["diffuseAmount", "specularAmount", "glossiness", "opacity"])
            assert(abs(num(s[field]) - num(o[field])) < EPS,
                "surface " ~ i.to!string ~ " " ~ field
                ~ " mismatch: expected " ~ num(o[field]).to!string
                ~ ", got " ~ num(s[field]).to!string);
    }

    if (exists(path)) remove(path);
}
