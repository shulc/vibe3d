// test_model_json_nonfinite.d — task 1550.
//
// `/api/model` MUST STAY PARSEABLE WHEN THE GEOMETRY IS NOT.
//
// The measured defect (found by the fuzz registry, task 1412, 47 witnesses):
// one infinite coordinate anywhere in the mesh made the whole body print bare
// `inf` / `-inf` / `-nan` tokens, which are not JSON. The endpoint became
// unreadable for EVERY client at once — this suite, the perf harness, any
// external tool — while the command that caused it answered `ok` in 6 ms.
//
// WHY THE TESTS POISON THE MESH THEMSELVES. The biggest risk in this file is
// a test that is green because nothing broke. No existing test puts a
// non-number into the geometry, so the parse that every existing test already
// performs is never exercised against this failure. Every cell below except
// T0, T5 and T4' therefore STARTS by creating the corruption; run against the
// unfixed tree they fail. T0 is the mirror image — it starts by trying to
// create it and asserts that it cannot.
//
// WHY THERE ARE TWO POISON PATHS. The card asked whether a non-number can
// reach `mesh.vertices` other than through a command parameter, because if it
// cannot, clamping the input would be enough and the serialiser would not need
// touching. It can: `io/native.d`'s `.v3d` reader takes vertex positions
// through `jsonFloat`, which casts a JSON double to `float` with NO finiteness
// check, and the reader's validation covers only the shape of the triple, the
// face indices and the item transform. `1e39` is legal JSON and
// `cast(float)1e39` is infinity. T6 drives exactly that path, and it is the
// case that stays red if someone "fixes" this by clamping `prim.cube`.
//
// THE PARAMETER PATH IS NOW CLOSED, AND THAT PREDICTION IS WHY (task 3150).
// Task 3020's parameter gate refuses a value the target type cannot hold —
// `sizeX:1e39` is a finite JSON double and an infinite `float`, so
// `paramGateFloat` narrows, sees the infinity and refuses. `prim.cube` answers
// `status:error` and builds nothing. Every cell below that opened with
// `poisonViaParam` was therefore asserting against a defect that no longer
// exists: T1 failed on its own `must still answer ok`, and T2/T3/T7 were
// invisible behind it (druntime stops a module at the first failed assert)
// while being just as vacuous — they would have read a healthy cube.
//
// So the poison moved to the path that is still open, exactly the one this
// file predicted would survive a `prim.cube` clamp, and the closed one became
// T0: the refusal is now ASSERTED, so the defect cannot quietly reopen. A file
// full of cells that can no longer fail is a checkpoint nobody can fail; the
// repair is to re-aim them at a live poison, not to delete the claims.
//
// TRANSPORT NOTE. The poison must be delivered as a JSON params object, NOT as
// an argstring: the argstring number grammar (source/argstring.d) has no
// exponent, so `prim.cube sizeX:1e39` written as an argstring does not deliver
// 1e39 at all and the test would be inert.
//
// WORKER HYGIENE. One long-lived `vibe3d --test` serves many tests on one
// port, so (a) the temporary `.v3d` is named after the PORT rather than a
// constant — two `-j 8` workers sharing one path is a race — and (b) every
// poisoning case ends with `/api/reset`, or the worker's document keeps the
// infinite geometry and `io/doc_state.d` keeps remembering the temp path.
import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv     : to;
import std.format   : format;
import std.string   : indexOf, lastIndexOf;
import std.file     : exists, remove, readText, write;
import std.exception: collectException;

// The shared client resolves the worker's private port from the environment.
// A hand-run binary retains the historical 8080 default.
alias kBase = testBaseUrl;

void main() {}

/// The port this binary was compiled for, read back out of `kBase` so the
/// temp-file name follows the selected worker port.
private string portTag() {
    return kBase[kBase.lastIndexOf(':') + 1 .. $];
}

private string tmpV3dPath() {
    return "/tmp/vibe3d-1550-" ~ portTag() ~ ".v3d";
}

private string rawGet(string path) {
    return cast(string) get(kBase ~ path);
}

private JSONValue postCmd(string body_) {
    auto http = HTTP();
    http.addRequestHeader("Content-Type", "application/json");
    return parseJSON(cast(string) post(kBase ~ "/api/command", body_, http));
}

private void reset() {
    post(kBase ~ "/api/command", commandBody("scene.reset"));
}

/// Drive `prim.cube` with an out-of-float-range size, as JSON params. Since
/// task 3020's parameter gate this REFUSES — T0 is the cell that says so.
private JSONValue poisonViaParam() {
    return postCmd(`{"id":"prim.cube","params":{"sizeX":1e39}}`);
}

/// Put an infinite coordinate into the LOADED DOCUMENT, through the `.v3d`
/// reader — the poison path that is still open, and the only one left.
///
/// Save a healthy cube, substitute exactly ONE coordinate in its `vertices`
/// block, load it back. Built from a file that is KNOWN to load because a
/// rejected fixture leaves a healthy mesh, and a red cell on a healthy mesh is
/// indistinguishable from the serialiser being broken. The fixture is verified
/// off disk before it is used, so a caller's failure cannot be this helper's.
///
/// Returns the fixture's own vertex count, so callers assert against the mesh
/// that actually loaded rather than a hard-coded 8.
private size_t poisonViaFile(string path) {
    if (exists(path)) remove(path);
    reset();

    auto sv = postCmd(format(`{"id":"file.save","params":{"path":"%s"}}`, path));
    assert(sv["status"].str == "ok", "poison fixture, file.save: " ~ sv.toString);
    assert(exists(path), "file.save answered ok but wrote no file at " ~ path);

    string txt = readText(path);
    const mi = txt.indexOf(`"mesh"`);
    assert(mi >= 0, "the saved document has no mesh block");
    const vi = txt.indexOf(`"vertices"`, mi);
    assert(vi >= 0, "the saved mesh has no vertices block");
    const ci = txt.indexOf("-0.5", vi);
    assert(ci >= 0, "expected the unit cube's first vertex to read -0.5");
    write(path, txt[0 .. ci] ~ "1e39" ~ txt[ci + 4 .. $]);

    // The substitution is exactly what we think it is, checked against the
    // file rather than assumed: vertex 0 x poisoned, y untouched.
    auto onDisk    = parseJSON(readText(path));
    auto fixVerts  = onDisk["layers"][0]["mesh"]["vertices"].array;
    auto dv        = fixVerts[0].array;
    assert(dv[0].floating == 1e39, "the fixture's x was not substituted");
    assert(dv[1].floating == -0.5, "the fixture's y must be untouched");
    assert(fixVerts.length >= 8,
        format("the fixture must be a real mesh, it has %d vertices",
               fixVerts.length));

    reset();
    auto ld = postCmd(format(`{"id":"file.load","params":{"path":"%s"}}`, path));
    assert(ld["status"].str == "ok",
        "the fixture must LOAD; a rejected fixture leaves a healthy mesh and "
      ~ "a red cell for the wrong reason: " ~ ld.toString);
    return fixVerts.length;
}

// ---------------------------------------------------------------------------
// T0 — the INVERTED cell: the parameter route no longer poisons anything.
//
// This cell used to read `prim.cube with sizeX:1e39 must still answer ok (it
// does — that is half of what makes this defect invisible)`. It was written to
// DOCUMENT a defect: a size no `float` can hold was accepted, answered ok in
// 6 ms, and put an infinity into the mesh. Task 3020's parameter gate closed
// it — `paramGateFloat` narrows the finite JSON double `1e39` to a `float`,
// sees an infinity, and refuses before anything is built — so the assertion
// failed BECAUSE THE BUG WAS GONE, which is the one way a test failure is good
// news.
//
// It is inverted rather than deleted. The claim it made is still the thing
// worth watching; only its sign changed, and an inverted cell is the guard
// that keeps the defect closed. Three assertions, because "it answered error"
// alone would also be satisfied by `prim.cube` being broken outright: the
// refusal must NAME the parameter, and the mesh must be the untouched cube.
// ---------------------------------------------------------------------------
unittest {
    reset();
    auto cmd = poisonViaParam();
    assert(cmd["status"].str == "error",
        format("prim.cube with sizeX:1e39 must be REFUSED at the parameter "
             ~ "gate — 1e39 is a finite double and an infinite float, and "
             ~ "there is no legal size for it to land on: %s", cmd.toString));
    assert(cmd["message"].str.indexOf("sizeX") >= 0,
        format("the refusal must name the offending parameter, or the caller "
             ~ "cannot act on it: %s", cmd.toString));

    // Nothing was built and nothing was poisoned — a refusal that half-applied
    // would be worse than the defect it replaced.
    auto body_ = parseJSON(rawGet("/api/model"));
    assert(body_["vertexCount"].integer == 8,
        format("the refused command must leave the reset cube alone, got %s",
               body_["vertexCount"].toString));
    assert(body_["nonFinite"]["count"].integer == 0,
        "a refused command must poison nothing: "
      ~ body_["nonFinite"].toString);

    reset();
}

// ---------------------------------------------------------------------------
// T1 — parseability. THE defect, driven by the poison path that is still open.
// ---------------------------------------------------------------------------
unittest {
    const path = "/tmp/vibe3d-1550-parse-" ~ portTag() ~ ".v3d";
    scope(exit) { if (exists(path)) remove(path); reset(); }
    poisonViaFile(path);

    const raw = rawGet("/api/model");

    // std.json rejects all four bare tokens, and this is NOT reachable through
    // an option: `JSONOptions.specialFloatLiterals` recognises the STRINGS
    // "Infinite"/"NaN", not bare `inf`/`nan`. So a body carrying them is
    // unparseable, full stop.
    auto e = collectException(parseJSON(raw));
    assert(e is null,
        "GET /api/model must return parseable JSON even when a coordinate is "
      ~ "not a number. It did not: " ~ (e is null ? "" : e.msg)
      ~ "\n  first 400 bytes of the body: "
      ~ raw[0 .. raw.length < 400 ? raw.length : 400]);

    reset();
}

// ---------------------------------------------------------------------------
// T2 — honesty. Valid JSON is not the same thing as truthful JSON.
// ---------------------------------------------------------------------------
unittest {
    const path = "/tmp/vibe3d-1550-honesty-" ~ portTag() ~ ".v3d";
    scope(exit) { if (exists(path)) remove(path); reset(); }
    poisonViaFile(path);

    auto body_ = parseJSON(rawGet("/api/model"));
    auto verts = body_["vertices"].array;

    size_t nulls;
    size_t zeros;
    foreach (v; verts)
        foreach (c; v.array) {
            if (c.type == JSONType.null_) { ++nulls; continue; }
            const d = c.type == JSONType.integer
                    ? cast(double) c.integer : c.floating;
            if (d == 0.0) ++zeros;
        }

    assert(nulls > 0,
        "a coordinate that is not a number must be published as JSON `null`. "
      ~ "None of the poisoned components was null, so either the poison did "
      ~ "not land or the serialiser is substituting something else.");

    // THIS is trap 1 of the card, and the reason T1 alone is not enough: a
    // serialiser that printed `0` would make T1 pass and would make the mesh
    // read as plausible-but-wrong — a cube whose corner sits at the origin
    // instead of a hole where a coordinate should be. Exactly ONE component of
    // the fixture is poisoned, so the count below is a wide margin by design.
    assert(zeros < verts.length * 3,
        "every component read as 0 — a serialiser that substitutes 0 for a "
      ~ "non-number produces valid JSON that LIES about where the geometry is");

    reset();
}

// ---------------------------------------------------------------------------
// T3 — the signal, on a damaged mesh.
// ---------------------------------------------------------------------------
unittest {
    const path = "/tmp/vibe3d-1550-signal-" ~ portTag() ~ ".v3d";
    scope(exit) { if (exists(path)) remove(path); reset(); }
    poisonViaFile(path);

    auto body_ = parseJSON(rawGet("/api/model"));
    assert("nonFinite" in body_.object,
        "/api/model must always carry a `nonFinite` block");
    auto nf = body_["nonFinite"];

    assert(nf["count"].integer > 0,
        format("`nonFinite.count` must count what was replaced, got %s",
               nf.toString));
    assert("first" in nf.object,
        "a non-zero count must name the FIRST occurrence: " ~ nf.toString);

    auto first = nf["first"];
    assert(first["array"].str == "vertices",
        "the first finding is a vertex here: " ~ first.toString);
    assert(first["component"].integer == 0,
        "the poisoned axis is X, i.e. component 0: " ~ first.toString);

    // The SIGN is deliberately not pinned. The fixture substitutes `1e39` for
    // a `-0.5`, so today it reads `inf`; but which sign a poisoned coordinate
    // carries is a property of the fixture, not of this contract, and pinning
    // it would make a harmless change to the fixture read as a broken
    // serialiser. Pinning a guessed sign is a test that goes red on correct
    // code.
    const v = first["value"].str;
    assert(v == "inf" || v == "-inf",
        format("`first.value` must report the offending value as a string, "
             ~ "either sign; got %s", first.toString));

    reset();
}

// ---------------------------------------------------------------------------
// T5 — the signal on a HEALTHY mesh. The block is always present, and a
// signal that always shouts "dirty" is as useless as one that never does.
// ---------------------------------------------------------------------------
unittest {
    reset();

    auto body_ = parseJSON(rawGet("/api/model"));
    assert("nonFinite" in body_.object,
        "the `nonFinite` block must be present on a healthy mesh too — that "
      ~ "is what makes a change that deletes the block redden this case and "
      ~ "not only the poisoned one");
    assert(body_["nonFinite"]["count"].integer == 0,
        "a freshly reset cube has no non-finite coordinate: "
      ~ body_["nonFinite"].toString);
    assert("first" !in body_["nonFinite"].object,
        "a zero count must not name a finding");

    // And every coordinate is a NUMBER, not a null.
    foreach (vtx; body_["vertices"].array)
        foreach (c; vtx.array)
            assert(c.type != JSONType.null_,
                "a healthy mesh must publish numbers, not nulls");
}

// ---------------------------------------------------------------------------
// T6 — the SECOND, non-parameter path: a `.v3d` whose vertex is out of float
// range. This is the case that separates "the serialiser was fixed" from
// "the command input was clamped".
//
// The fixture is built from a file that is KNOWN to load — save a healthy
// cube, then substitute exactly one coordinate — because a rejected fixture
// yields a healthy mesh and a red T6 that is indistinguishable from the
// serialiser being broken. The positive controls below run in order and each
// one rules out a different way of failing for the wrong reason.
// ---------------------------------------------------------------------------
unittest {
    const path = tmpV3dPath();
    scope(exit) { if (exists(path)) remove(path); reset(); }

    // The fixture, its on-disk verification and the "it really loads"
    // positive control all live in `poisonViaFile` now — T1/T2/T3/T7 need the
    // same poison since the parameter route closed, and one copy is one place
    // for it to be wrong. What stays here is what is specific to T6: the claim
    // that this SECOND path raises the same signal as the first one did.
    immutable size_t fixtureVerts = poisonViaFile(path);

    auto body_ = parseJSON(rawGet("/api/model"));

    // --- positive control: it is the fixture's mesh, not a leftover -------
    // The expected count is read OUT OF THE FIXTURE, not hard-coded: that is
    // what "the mesh that loaded is the mesh we wrote" actually claims, and it
    // survives a change to what `/api/reset` builds.
    assert(body_["vertexCount"].integer == cast(long) fixtureVerts,
        format("the loaded document must be the fixture's own mesh (%d "
             ~ "vertices), got %s", fixtureVerts,
               body_["vertexCount"].toString));

    // --- positive control: a FINITE component of the same vertex still
    //     reads as the number it was. Without this, an empty or all-null
    //     body would satisfy everything below.
    auto v0 = body_["vertices"][0].array;
    assert(v0[1].type != JSONType.null_,
        "the untouched y of the poisoned vertex must still be a number");
    assert(v0[1].floating == -0.5,
        format("the untouched y must read back as -0.5, got %s",
               v0[1].toString));

    // --- and only now, the claim -------------------------------------------
    assert(v0[0].type == JSONType.null_,
        format("the substituted x must publish as null, got %s",
               v0[0].toString));
    auto nf = body_["nonFinite"];
    assert(nf["count"].integer > 0,
        "the `.v3d` path must raise the same signal as the parameter path: "
      ~ nf.toString);
    assert(nf["first"]["array"].str == "vertices", nf.toString);
    assert(nf["first"]["index"].integer == 0,
        "the substituted vertex is index 0: " ~ nf.toString);
}

// ---------------------------------------------------------------------------
// T7 — the OTHER direction of the same defect: writing a `.v3d`.
//
// `/api/model` is a DIAGNOSTIC read, so it stays readable and reports a hole.
// `.v3d` is the document of record, so it REFUSES — a `null` there would be a
// lie about what the user saved. That refusal already existed (std.json's own
// encoder throws on infinity), and this case pins two things about it: that it
// is still LOUD, and that the message now names the vertex.
//
// The loudness half is not decoration. Measured on this tree: with the
// pre-flight removed the save answers `{"status":"error","message":"Cannot
// encode Infinity..."}` — useless but honest. A pre-flight written as
// `return false` instead of a throw would have answered `{"status":"ok"}` with
// no file on disk, because `FileSave` threads `writeV3d`'s return value into
// the dirty flag rather than into its own result. This case is what stops that
// swap from being silent.
// ---------------------------------------------------------------------------
unittest {
    const path = "/tmp/vibe3d-1550-save-" ~ portTag() ~ ".v3d";
    if (exists(path)) remove(path);
    scope(exit) { if (exists(path)) remove(path); reset(); }

    const src = "/tmp/vibe3d-1550-savesrc-" ~ portTag() ~ ".v3d";
    scope(exit) if (exists(src)) remove(src);
    poisonViaFile(src);

    // Deliberately a DIFFERENT path from the one just loaded: the refusal is a
    // property of the geometry, not of the destination, and a save-over-source
    // could refuse for a file-handling reason instead of the one under test.
    auto sv = postCmd(format(`{"id":"file.save","params":{"path":"%s"}}`, path));
    assert(sv["status"].str != "ok",
        "saving a mesh with a non-finite vertex must FAIL, loudly. A quiet "
      ~ "`ok` with no file on disk is the worst of both: " ~ sv.toString);
    assert(!exists(path),
        "the refused write must leave no file behind at " ~ path);

    const msg = sv["message"].str;
    assert(msg.indexOf("vertex") >= 0 && msg.indexOf("not finite") >= 0,
        "the refusal must NAME the offending vertex — `Cannot encode "
      ~ "Infinity` from inside std.json identifies neither the item nor the "
      ~ "index and is not something a user can act on. Got: " ~ msg);
}

// ---------------------------------------------------------------------------
// T4' — the SPECIFIER, asserted on the RAW body, at a real call site.
//
// This replaces a module-unittest of the shape `jsonNum(v, spec) ==
// format(spec, v)`, which was inert three ways: it read no call site (which is
// where specifier drift happens), no mutation in the task's table reddened it,
// and it only restated the helper's definition. No parsing test can replace it
// either — `1.000000` and `1.000` are the same JSON number.
//
// One assertion per specifier FAMILY in the tree. The other 21 sites have no
// behavioural witness and are covered structurally by
// tests/unit/json_emitter_scan_test.d's frozen per-file census; that boundary
// is stated in the task card rather than left implicit.
// ---------------------------------------------------------------------------
unittest { // (a) `%f` — /api/model vertices
    reset();
    const raw = rawGet("/api/model");
    assert(raw.indexOf("-0.500000") >= 0,
        "the reset cube's -0.5 must print at `%f` (six fixed decimals). A "
      ~ "`%.3f` would print -0.500 and every parsing test in the suite would "
      ~ "stay green.\n  first 300 bytes: "
      ~ raw[0 .. raw.length < 300 ? raw.length : 300]);
}

unittest { // (b) `%.6f` — /api/layers item transform
    reset();
    const raw = rawGet("/api/layers");
    assert(raw.indexOf(`"scl":[1.000000,1.000000,1.000000]`) >= 0,
        "the identity item scale must print at `%.6f`.\n  body: " ~ raw);
}

unittest { // (c) `%.9g` — /api/camera orientation
    // `%.9g` is the one specifier in the tree whose precision is load-bearing:
    // nine significant digits is the round-trip precision of a 32-bit float,
    // and source/view.d's own doc comment explains that losing them tilts the
    // horizon a little on every save and load. `%.9g` prints 1 and 0 as `1`
    // and `0`; `%f` would print `1.000000` and `0.000000`.
    auto http = HTTP();
    http.addRequestHeader("Content-Type", "application/json");

    const before = rawGet("/api/camera");
    auto  keep   = parseJSON(before)["orientation"].toString();

    post(kBase ~ "/api/camera", `{"orientation":[1,0,0,0,1,0,0,0,1]}`, http);
    const raw = rawGet("/api/camera");

    // Put the camera back before asserting, so a failure here does not leave
    // the worker's camera pointing somewhere the next test does not expect.
    auto http2 = HTTP();
    http2.addRequestHeader("Content-Type", "application/json");
    post(kBase ~ "/api/camera", `{"orientation":` ~ keep ~ `}`, http2);

    assert(raw.indexOf(`"orientation":[1,0,0,0,1,0,0,0,1]`) >= 0,
        "the identity orientation must print at `%.9g`, i.e. as bare 1s and "
      ~ "0s. A `%f` here would print 1.000000 and silently cost seven bits of "
      ~ "the mantissa on every real orientation.\n  body: " ~ raw);
}
