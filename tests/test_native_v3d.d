// Tests for the native .v3d document format round-trip via /api/command.
//
// Flow:
//   reset → mark every face subpatch → save to /tmp/x.v3d → mutate state
//   → load /tmp/x.v3d → /api/model topology + subpatch + surfaces match the
//   original cube exactly.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write, readText;
import std.conv : to;
import std.format : format;
import std.algorithm : canFind;

void main() {}

/// THIS BUILD's `.v3d` format version, read out of a document the running app
/// just wrote.
///
/// The obvious alternative is `import io.native : kV3dFormatVersion`, which is
/// what `tests/test_uv_pipeline.d` does. Not taken here for two reasons: this
/// file is an HTTP driver, and importing a project module flips it onto
/// `run_test.d`'s heavy source-backed compile line (it would be the only HTTP
/// test to pay that); and a number read from a file the app PRODUCED is a
/// better oracle for "what will this reader accept" than the constant the
/// reader is compiled against. Either way the point is the same — the number
/// is never written down here, so a format bump cannot silently re-inert the
/// fixtures below.
int currentFormatVersion() {
    static int cached = 0;
    if (cached != 0) return cached;
    enum string probe = "/tmp/vibe3d-test-formatversion-probe.v3d";
    resetCube();
    runCmd("file.save", `{"path":"` ~ probe ~ `"}`);
    scope(exit) if (exists(probe)) remove(probe);
    auto j = parseJSON(readText(probe));
    assert("formatVersion" in j,
        "a document this build wrote must declare its version: " ~ j.toString);
    cached = cast(int) j["formatVersion"].integer;
    assert(cached > 0, "…and it must be a real version number");
    return cached;
}

/// A well-formed v3d envelope at THIS BUILD's format version, wrapped around
/// one `layers` entry.
///
/// NOT a hardcoded `8` (review, inert-assertion 8). The four malformed-mesh
/// fixtures below each name a specific mesh-codec check, and each carried a
/// stale literal version (`4`) — so every one of them was rejected at the
/// VERSION GATE and never reached the codec it claims to exercise. Task 0616
/// Ph6 re-pointed them at `8`, which fixed the symptom and left the mechanism
/// in place: the next format bump silently re-inerts all four in exactly the
/// same way. Deriving the envelope means a bump cannot do that again.
string v3dEnvelope(string layerBody) {
    return format(`{"formatVersion":%d,"primaryLayer":0,"layers":[%s]}`,
                  currentFormatVersion(), layerBody);
}

/// A mesh layer entry carrying an arbitrary `mesh` sub-object.
string meshLayer(string meshBody) {
    return `{"type":"mesh","selected":true,"channels":{"name":"L","visible":true},`
         ~ `"mesh":` ~ meshBody ~ `}`;
}

/// Assert a `file.load` was refused, and refused BY THE CHECK THE TEST NAMES.
///
/// `status == "error"` alone cannot tell a mesh-codec reject from a version
/// -gate reject — which is precisely how the four fixtures below passed for
/// years while never reaching their own subject. The reader's version-gate
/// wording is a contract (task 0616 Ph6), so its phrases are a reliable
/// negative needle: if any of them appears, the file was thrown out for its
/// envelope and the codec never ran.
void assertRejectedByCodec(string resp, string what) {
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for " ~ what ~ ", got: " ~ resp);
    immutable msg = ("message" in j) ? j["message"].str : "";
    foreach (needle; ["format version", "formatVersion", "not damaged"])
        assert(!msg.canFind(needle),
            "the load was refused at the VERSION GATE, not by the " ~ what
            ~ " check this test is about — the fixture's envelope is stale. "
            ~ "Got: " ~ resp);
}

void resetCube() {
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post(testBaseUrl() ~ "/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        id ~ " failed: " ~ resp);
}

string runCmdAllowError(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return cast(string)post(testBaseUrl() ~ "/api/command", body);
}

JSONValue model() {
    return parseJSON(get(testBaseUrl() ~ "/api/model"));
}

unittest { // save → load round-trip preserves geometry, subpatch and surfaces
    enum string path = "/tmp/vibe3d-test-roundtrip.v3d";
    if (exists(path)) remove(path);

    resetCube();

    // Mark every face as subpatch so the round-trip has a non-trivial flag
    // array to preserve. With no face selection mesh.subpatch_toggle inverts
    // the flag on every face (all false → all true on a fresh cube).
    post(testBaseUrl() ~ "/api/command", "select.typeFrom polygon");
    runCmd("mesh.subpatch_toggle");

    auto orig = model();
    long origV = orig["vertexCount"].integer;
    long origE = orig["edgeCount"].integer;
    long origF = orig["faceCount"].integer;
    assert(origV == 8 && origE == 12 && origF == 6, "cube prerequisite");

    // Capture the exact arrays we expect to survive the round-trip.
    auto origFaces      = orig["faces"];
    auto origVertices   = orig["vertices"];
    auto origSubpatch   = orig["isSubpatch"];
    auto origSurfaces   = orig["surfaces"];
    // Every face should now be a subpatch.
    foreach (b; origSubpatch.array)
        assert(b.type == JSONType.true_, "expected all faces subpatch after toggle");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Mutate the scene so a stale state can't masquerade as a successful load.
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

    // Exact vertex positions (float text is deterministic — same %f formatter
    // on both the saved and reloaded mesh, identical values).
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

    // Exact face vertex-index lists.
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

    // Subpatch flags survive.
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

    if (exists(path)) remove(path);
}

unittest { // file.load on a non-existent .v3d returns error, doesn't crash
    enum string path = "/tmp/vibe3d-test-nonexistent.v3d";
    if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for missing file, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8, "mesh should be intact after failed load");
}

unittest { // file.load on a malformed-JSON .v3d returns error
    enum string path = "/tmp/vibe3d-test-junk.v3d";
    write(path, "{ this is not valid json ]]]");
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for malformed JSON, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after junk-file load");
}

unittest { // a wrong/future formatVersion is rejected cleanly
    enum string path = "/tmp/vibe3d-test-badver.v3d";
    write(path,
        `{"formatVersion":999,"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,2]]}}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for unsupported formatVersion, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after bad-version load");
}

// ---------------------------------------------------------------------------
// THE REFUSAL REACHES THE CALLER, WORD FOR WORD (review B1).
//
// The most ordinary thing a user of a pre-v8 build can do is open a document
// they already have. The reader has always written a careful sentence for that
// case — it names the file's version, this build's, and says the file is not
// damaged, because "could not open" reads as corruption and sends people
// hunting a problem that does not exist. But it wrote that sentence to the
// LOG, whose only sink is a stderr echo, and `Command.refusalReason()` was not
// overridden — so `/api/command` answered a bare `{"status":"error"}` and the
// File menu did nothing visible at all.
//
// This is the assertion that the message travels. It reads the SAME string a
// scripted caller gets and the modal notice shows, out of the live app over
// HTTP — not out of a log listener that the application never installs, which
// is what the in-module test used to do and why it could not have caught this.
//
// Discriminating: `status == "error"` was already true before the fix (the
// load always failed); every needle below was absent. A `refusalReason` that
// forwards a generic "could not open" reads none of them either.
// ---------------------------------------------------------------------------
unittest {
    enum string path = "/tmp/vibe3d-test-oldver-message.v3d";
    // One BELOW this build's version: a document written by an earlier build,
    // which is the case the wording was written for. Derived, so the fixture
    // stays "the previous version" forever.
    immutable int cur = currentFormatVersion();
    write(path, format(
        `{"formatVersion":%d,"primaryLayer":0,"layers":[{"type":"mesh",`
        ~ `"selected":true,"channels":{"name":"L","visible":true},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}]}`,
        cur - 1));
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto j = parseJSON(runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`));
    assert(j["status"].str == "error", "a pre-current document is refused");
    assert("message" in j, "…and the refusal carries a message: " ~ j.toString);
    immutable msg = j["message"].str;

    assert(msg.canFind(format("format version %d", cur - 1)),
        "the message names the FILE's version — without it the user cannot "
        ~ "tell which of their documents this is. Got: " ~ msg);
    assert(msg.canFind(format("version %d", cur)),
        "…and THIS BUILD's, or they cannot tell what would open it. Got: "
        ~ msg);
    assert(msg.canFind("not damaged"),
        "…and says the file is fine, which is the whole point of the wording. "
        ~ "Got: " ~ msg);
    assert(msg.canFind(path),
        "…and names the file, because a modal dialog has no other context. "
        ~ "Got: " ~ msg);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "control: the refusal left the open document alone");
}

unittest { // a face index >= 2^63 (parsed as uinteger by std.json) rejects cleanly
    // Critical durability case: such a literal must NOT throw an uncaught
    // JSONException when the reader pulls the index — it must degrade to a
    // clean error with the prior cube left untouched.
    //
    // The envelope is `v3dEnvelope`, i.e. DERIVED from what this build writes,
    // and the rejection is checked with `assertRejectedByCodec`. Both matter,
    // and the history says why: these four malformed-mesh fixtures carried
    // `formatVersion: 4`, so every one of them was rejected at the VERSION
    // GATE and never reached the mesh codec it names. Ph6 re-pointed them at a
    // literal `8` — which fixed the symptom and left the mechanism in place,
    // ready to re-inert all four on the next bump. See the two helpers at the
    // top of this file.
    enum string path = "/tmp/vibe3d-test-hugeindex.v3d";
    write(path, v3dEnvelope(meshLayer(
        `{"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,99999999999999999999]]}`)));
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    assertRejectedByCodec(resp, "huge uinteger face index");

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after huge-index load");
}

unittest { // a non-object root is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonobjroot.v3d";
    write(path, `[1,2,3]`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for non-object root, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-object-root load");
}

unittest { // a non-array "vertices" is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonarrayverts.v3d";
    write(path, v3dEnvelope(meshLayer(`{"vertices":42,"faces":[[0,1,2]]}`)));
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    assertRejectedByCodec(resp, "non-array vertices");

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-array-vertices load");
}

unittest { // a non-array "faces" is rejected cleanly
    enum string path = "/tmp/vibe3d-test-nonarrayfaces.v3d";
    write(path, v3dEnvelope(meshLayer(
        `{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":"nope"}`)));
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    assertRejectedByCodec(resp, "non-array faces");

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after non-array-faces load");
}

unittest { // an in-range-typed but out-of-range vertex index rejects cleanly
    enum string path = "/tmp/vibe3d-test-oob-index.v3d";
    write(path, v3dEnvelope(meshLayer(
        `{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,7]]}`)));
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    assertRejectedByCodec(resp, "out-of-range vertex index");

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after out-of-range-index load");
}
