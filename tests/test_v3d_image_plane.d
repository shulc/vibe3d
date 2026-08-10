// Task 0612 Stage 9 — the `.v3d` proof for the reference-image plane, and the
// ENUMERATION behind it: every field of every item kind, and what survives.
//
// WHY THIS FILE EXISTS AND NOT AN `io/native.d` UNITTEST. The plan reserved
// this location so a `git diff` gate over the codec could stay measurable. The
// gate did not survive contact (see below); the location is kept anyway,
// because these cases drive the real `file.save` / `file.load` COMMANDS. An
// in-module test calls `writeV3d`/`readV3d` with a hand-built `Document` and
// therefore cannot see whether the item a user can actually create is the item
// the codec is handed.
//
// ---------------------------------------------------------------------------
// THE FINDING THIS STAGE WAS BUILT TO FIX, stated because it is the whole
// content of the stage.
//
// `.v3d` v8 needed no schema change for this kind: the wire token is table-
// driven, the ten channels ride the generic `channels` object with no key list
// in the codec, the twelve transform components are already in there, and the
// clip reference rides the `links` array. All true, all still true —
// `kV3dFormatVersion` is still 8.
//
// What that analysis missed is that `io/native.d`'s reader has a payload block
// doing TWO jobs: it reads a payload off the wire, and it CONSTRUCTS the object
// the channel injection binds its pointers into. It had an arm for `hasMesh`
// and an arm for `hasImage` and nothing else. So a saved plane round-tripped
// its envelope perfectly — token, name, visibility, all twelve components, the
// link — and came back with a null payload, at which point `layer_params.d`'s
// bundle takes its documented null-payload fallback to the BASE bundle and
// every one of the ten channels in the file is ignored. Silently: the channel
// injector skips a key it does not recognise, and a plane with no channels is
// not an error, it is an item with fewer rows in the panel.
//
// The lesson worth carrying: for a payload-bearing kind, "does it need a block
// in the file?" and "does the reader need to construct it?" are different
// questions with different answers, and only the first one is about the schema.
//
// ---------------------------------------------------------------------------
// WHAT MAKES THESE ASSERTIONS ABLE TO FAIL
//
// Every value written below is NON-DEFAULT, and that is load-bearing rather
// than thorough: a channel that is dropped anywhere in the chain reads its
// default, so a fixture that happened to set a default value would pass on a
// writer that never wrote it and on a reader that never read it. The floats
// are pairwise distinct so a cross-wiring lands on a different number rather
// than on the same one.
//
// A ROUND-TRIP ALONE CANNOT PIN A WIRE MEANING — if the writer and the reader
// agree on a wrong encoding, save-then-load returns the right answer. So case 2
// reads the raw saved JSON and asserts the values IN THE FILE, and case 3
// hand-MUTATES that file and reloads, which is the only way to prove the reader
// is reading the file rather than finding the state already in memory.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs;
import std.format : format;
import std.file   : write, copy, exists, mkdirRecurse, rmdirRecurse, readText,
                    tempDir;
import std.path   : buildPath, dirName;
import std.algorithm : canFind;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue cmdRaw(string body_) {
    return parseJSON(cast(string) post(baseUrl ~ "/api/command", body_));
}

JSONValue cmd(string body_) {
    auto j = cmdRaw(body_);
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string) post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue getLayers()       { return parseJSON(cast(string) get(baseUrl ~ "/api/layers")); }
JSONValue layerAt(size_t i) { return getLayers()["layers"].array[i]; }
size_t    layerCount()      { return getLayers()["layers"].array.length; }
string    jsonStr(string s) { return JSONValue(s).toString(); }

/// Read one channel back through the generic attribute path. This IS the
/// payload probe: with no payload object constructed, the channel is not
/// declared at all and the command reports an unknown attribute — so a
/// successful read is already evidence, before the value is compared.
JSONValue attr(size_t idx, string name) {
    auto r = cmdRaw("layer.attr " ~ idx.to!string ~ " " ~ name ~ " ?");
    assert(r["status"].str == "ok",
        "reading `" ~ name ~ "` off layer " ~ idx.to!string ~ " failed. For a "
        ~ "payload-bearing kind this is what a NULL PAYLOAD looks like from "
        ~ "outside: the channel is not declared, so it cannot be read and "
        ~ "cannot be written. " ~ r.toString);
    return r["value"];
}

double attrF(size_t idx, string name) {
    auto v = attr(idx, name);
    return v.type == JSONType.integer ? cast(double) v.integer : v.floating;
}
bool   attrB(size_t idx, string name) { return attr(idx, name).boolean; }
string attrS(size_t idx, string name) { return attr(idx, name).str; }

bool approx(double a, double b, double eps = 1e-5) { return fabs(a - b) < eps; }

/// A wiped scratch directory — a file left by an earlier run (including a
/// deliberate-break run) is otherwise visible to the next one.
string scratch(string tag) {
    auto d = buildPath(tempDir(), "vibe3d_v3dplane_" ~ tag);
    if (exists(d)) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

/// A minimal uncompressed 24-bit BMP. A local copy on purpose: run_test.d
/// compiles every helper module into every test, so a shared helper is a
/// project-wide name for twenty lines.
string bmpAt(string path, int w, int h) {
    mkdirRecurse(dirName(path));
    ubyte[] b;
    void u16(ushort v) { b ~= cast(ubyte)(v & 0xFF); b ~= cast(ubyte)((v >> 8) & 0xFF); }
    void u32(uint v) {
        b ~= cast(ubyte)(v & 0xFF);         b ~= cast(ubyte)((v >> 8)  & 0xFF);
        b ~= cast(ubyte)((v >> 16) & 0xFF); b ~= cast(ubyte)((v >> 24) & 0xFF);
    }
    immutable size_t rowBytes = cast(size_t)((w * 3 + 3) & ~3);
    immutable size_t pixBytes = rowBytes * h;
    b ~= cast(ubyte)'B'; b ~= cast(ubyte)'M';
    u32(cast(uint)(54 + pixBytes));
    u16(0); u16(0); u32(54); u32(40);
    u32(cast(uint) w); u32(cast(uint) h);
    u16(1); u16(24); u32(0); u32(cast(uint) pixBytes);
    u32(2835); u32(2835); u32(0); u32(0);
    foreach (y; 0 .. h) {
        foreach (x; 0 .. w) {
            b ~= cast(ubyte)(x * 7 + 3); b ~= cast(ubyte)(y * 11 + 5); b ~= cast(ubyte)(x * 3 + y);
        }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

// ---------------------------------------------------------------------------
// THE FIXTURE VALUES — one table, used by the write, the file inspection, the
// read-back and the enumeration, so no case can drift from another.
//
// `keepAspect` and `showInPerspective` are the two channels whose NON-default
// value is `false`. (The plan says `keepAspect` is "the one"; it is one of
// two.) Their being false is what makes them able to fail: a channel written
// only when truthy, or defaulted on read, reads `true` for both.
//
// RESIDUAL, named rather than hidden: five booleans cannot be pairwise
// distinct. A defect that SWAPPED two same-valued booleans would be invisible
// here. It is also not reachable — the channel block is keyed by NAME on both
// sides, so the failure modes are "dropped" and "not injected", which
// non-default values do catch. The floats carry the distinctness burden.
// ---------------------------------------------------------------------------
immutable string kProjection        = "right";   // default "front"
immutable bool   kShowInPerspective = false;     // default true
immutable double kPixelSize         = 0.037;     // default 0.01
immutable bool   kKeepAspect        = false;     // default true
immutable double kBrightness        = 0.25;      // default 0
immutable double kContrast          = -0.5;      // default 0
immutable double kTransparency      = 0.75;      // default 0
immutable bool   kInvert            = true;      // default false
immutable bool   kFlipHorizontal    = true;      // default false
immutable bool   kSmooth            = true;      // default false

// A twelve-component pose with no 90° multiple, one NEGATIVE scale component
// and a non-zero pivot. The negative scale is deliberate and asserted only as
// a COMPONENT round-trip: what extent a negative scale produces is unmeasured
// and asserting it here would freeze a guess.
immutable double[3] kPos   = [ 1.25, -3.5,  0.75];
immutable double[3] kRot   = [17.0,  -41.0, 63.0];
immutable double[3] kScl   = [ 2.5,  -1.75, 0.5 ];
immutable double[3] kPivot = [-0.25,  0.5, -0.125];

void writePlaneChannels(size_t idx) {
    cmd(format("layer.attr %d projection %s",        idx, kProjection));
    cmd(format("layer.attr %d showInPerspective %s", idx, kShowInPerspective ? "true" : "false"));
    cmd(format("layer.attr %d pixelSize %.6f",       idx, kPixelSize));
    cmd(format("layer.attr %d keepAspect %s",        idx, kKeepAspect ? "true" : "false"));
    cmd(format("layer.attr %d brightness %.6f",      idx, kBrightness));
    cmd(format("layer.attr %d contrast %.6f",        idx, kContrast));
    cmd(format("layer.attr %d transparency %.6f",    idx, kTransparency));
    cmd(format("layer.attr %d invert %s",            idx, kInvert ? "true" : "false"));
    cmd(format("layer.attr %d flipHorizontal %s",    idx, kFlipHorizontal ? "true" : "false"));
    cmd(format("layer.attr %d smooth %s",            idx, kSmooth ? "true" : "false"));
}

/// A second, DIFFERENT twelve-component pose. The enumeration puts one on the
/// `empty` and one on the plane: with a single shared pose, a reader that
/// wrote every layer's transform from the same source would pass.
immutable double[3] kPos2   = [-4.5,   2.25, -1.5 ];
immutable double[3] kRot2   = [-11.0, 29.0,  -53.0];
immutable double[3] kScl2   = [ 0.75, 3.25,  -2.0 ];
immutable double[3] kPivot2 = [ 0.375, -0.75, 0.625];

void writePose(size_t idx, bool second = false) {
    static immutable string[3] ax = ["x", "y", "z"];
    auto pos   = second ? kPos2   : kPos;
    auto rot   = second ? kRot2   : kRot;
    auto scl   = second ? kScl2   : kScl;
    auto pivot = second ? kPivot2 : kPivot;
    foreach (i, a; ax) cmd(format("layer.attr %d pos.%s %.6f",   idx, a, pos[i]));
    foreach (i, a; ax) cmd(format("layer.attr %d rot.%s %.6f",   idx, a, rot[i]));
    foreach (i, a; ax) cmd(format("layer.attr %d scl.%s %.6f",   idx, a, scl[i]));
    foreach (i, a; ax) cmd(format("layer.attr %d pivot.%s %.6f", idx, a, pivot[i]));
}

void assertPlaneChannels(size_t idx, string where) {
    assert(attrS(idx, "projection") == kProjection,
        where ~ ": projection — got " ~ attrS(idx, "projection"));
    assert(attrB(idx, "showInPerspective") == kShowInPerspective,
        where ~ ": showInPerspective");
    assert(approx(attrF(idx, "pixelSize"), kPixelSize),
        format("%s: pixelSize — want %.6f got %.6f", where, kPixelSize, attrF(idx, "pixelSize")));
    assert(attrB(idx, "keepAspect") == kKeepAspect, where ~ ": keepAspect");
    assert(approx(attrF(idx, "brightness"), kBrightness),
        format("%s: brightness — want %.6f got %.6f", where, kBrightness, attrF(idx, "brightness")));
    assert(approx(attrF(idx, "contrast"), kContrast),
        format("%s: contrast — want %.6f got %.6f", where, kContrast, attrF(idx, "contrast")));
    assert(approx(attrF(idx, "transparency"), kTransparency),
        format("%s: transparency — want %.6f got %.6f", where, kTransparency, attrF(idx, "transparency")));
    assert(attrB(idx, "invert") == kInvert,                 where ~ ": invert");
    assert(attrB(idx, "flipHorizontal") == kFlipHorizontal, where ~ ": flipHorizontal");
    assert(attrB(idx, "smooth") == kSmooth,                 where ~ ": smooth");
}

void assertPose(size_t idx, string where, bool second = false) {
    auto x = layerAt(idx)["xform"];
    static immutable string[4] fields = ["pos", "rot", "scl", "pivot"];
    double[3][4] want = second ? [kPos2, kRot2, kScl2, kPivot2]
                               : [kPos,  kRot,  kScl,  kPivot];
    foreach (fi, f; fields)
        foreach (c; 0 .. 3)
            assert(approx(x[f].array[c].floating, want[fi][c], 1e-4),
                format("%s: xform.%s[%d] — want %.6f got %.6f",
                       where, f, c, want[fi][c], x[f].array[c].floating));
}

/// The plane's `image` link row from `/api/layers`, or a null JSONValue.
JSONValue imageLink(size_t idx) {
    foreach (s; layerAt(idx)["links"].array)
        if (s["slot"].str == "image") return s;
    return JSONValue(null);
}

/// Three clips on three DIFFERENT files, the plane bound to the MIDDLE one.
/// Three, not one: one clip cannot tell a real reference from "resolved to the
/// only one there was". Different files, not one shared file: the shared-path
/// decoy is `test_image_plane_link.d`'s job (it separates object identity from
/// path identity); here the clips must be distinguishable AFTER a reload,
/// which is what different paths buy.
struct Fixture {
    string dir;
    string doc;
    size_t plane;        // layer index of the plane
    size_t middleClip;   // layer index of the bound clip
}

Fixture buildFixture(string tag) {
    Fixture f;
    f.dir = scratch(tag);
    f.doc = buildPath(f.dir, "scene.v3d");
    resetCube();
    foreach (i, nm; ["alpha.bmp", "bravo.bmp", "charlie.bmp"])
        cmd(`{"id":"image.load","path":`
            ~ jsonStr(bmpAt(buildPath(f.dir, nm), cast(int)(3 + i), cast(int)(2 + i * 2)))
            ~ `}`);
    // [0] cube  [1] alpha  [2] bravo  [3] charlie
    f.middleClip = 2;
    assert(layerAt(f.middleClip)["type"].str == "image", "fixture: clips at 1..3");
    cmd(`{"id":"imagePlane.add","params":{"name":"Reference","projection":"front"}}`);
    f.plane = layerCount() - 1;
    cmd(format(`{"id":"imagePlane.setImage","params":{"index":%d,"image":%d}}`,
               f.plane, f.middleClip));
    auto lk = imageLink(f.plane);
    assert(lk.type != JSONType.null_ && lk["target"].integer == cast(long) f.middleClip,
        "fixture: the plane is bound to the MIDDLE clip before the save — "
        ~ lk.toString);
    writePlaneChannels(f.plane);
    writePose(f.plane);
    return f;
}

// ===========================================================================
// T-S1 — the format version, read off the BYTES rather than off the constant.
//
// `tests/test_uv_pipeline.d:106` asserts `kV3dFormatVersion == 8` against the
// symbol and must not be edited; this asserts the number a file actually
// carries, which is the thing a document written by an older build would be
// compared against. A version bump to carry this kind — the tempting fix for
// the payload finding above, and the wrong one — reads 9 here.
// ===========================================================================
unittest {
    auto f = buildFixture("version");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(f.doc) ~ `}}`);
    auto j = parseJSON(readText(f.doc));
    assert(j["formatVersion"].integer == 8,
        format("T-S1: a document holding a reference-image plane is still "
             ~ "v8 — the kind needed no schema step, only a reader that "
             ~ "constructs its payload. got %d", j["formatVersion"].integer));
}

// ===========================================================================
// T-S2 — save → load → every channel, every component, and the link target.
//
// Case (a) inspects the FILE, so the writer is pinned independently of the
// reader. Case (b) is the round trip. Both are needed: (b) alone passes on a
// writer and reader that agree on a wrong encoding, (a) alone passes on a
// reader that ignores what was written.
//
// Wrong implementations and what they read:
//   * the reader constructs no payload (the shipped bug) — every `layer.attr`
//     read in (b) FAILS outright, because with no payload the channel is not
//     declared. That is the loudest possible form of the failure and it is
//     still silent to a user.
//   * a channel dropped from the writer — that channel reads its DEFAULT,
//     which is why every value here is non-default.
//   * the payload constructed AFTER the channel injection — the file's values
//     are written into pointers that are about to be replaced, so every
//     channel reads its default while the payload exists. (a) passes, (b) fails.
// ===========================================================================
unittest {
    auto f = buildFixture("roundtrip");
    assertPlaneChannels(f.plane, "pre-save");     // the fixture really holds them

    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(f.doc) ~ `}}`);

    // --- (a) the FILE ----------------------------------------------------
    auto j = parseJSON(readText(f.doc));
    auto lj = j["layers"].array[f.plane];
    assert(lj["type"].str == "imagePlane",
        "T-S2a: the wire token — got " ~ lj["type"].str);
    assert("imagePlane" !in lj,
        "T-S2a: the plane has NO payload block of its own. If one ever "
        ~ "appears the schema claim (\"v8 carries this kind unchanged\") has "
        ~ "quietly stopped being true and the version step it was avoiding is "
        ~ "owed. keys: " ~ lj.object.keys.to!string);
    auto ch = lj["channels"];
    assert(ch["projection"].str == kProjection, "T-S2a: projection in the file");
    assert(ch["showInPerspective"].boolean == kShowInPerspective, "T-S2a: showInPerspective");
    assert(approx(ch["pixelSize"].floating, kPixelSize), "T-S2a: pixelSize in the file");
    assert(ch["keepAspect"].boolean == kKeepAspect, "T-S2a: keepAspect in the file");
    assert(approx(ch["brightness"].floating,   kBrightness),   "T-S2a: brightness");
    assert(approx(ch["contrast"].floating,     kContrast),     "T-S2a: contrast");
    assert(approx(ch["transparency"].floating, kTransparency), "T-S2a: transparency");
    assert(ch["invert"].boolean         == kInvert,         "T-S2a: invert");
    assert(ch["flipHorizontal"].boolean == kFlipHorizontal, "T-S2a: flipHorizontal");
    assert(ch["smooth"].boolean         == kSmooth,         "T-S2a: smooth");
    auto lks = lj["links"].array;
    assert(lks.length == 1 && lks[0]["slot"].str == "image"
                           && lks[0]["target"].integer == cast(long) f.middleClip,
        "T-S2a: the link names the MIDDLE clip by whole-array index — "
        ~ lj["links"].toString);

    // --- (b) the ROUND TRIP ----------------------------------------------
    resetCube();
    assert(layerCount() == 1, "the reset really cleared the document");
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(f.doc) ~ `}}`);

    assert(layerAt(f.plane)["type"].str == "imagePlane", "T-S2b: the kind came back");
    assert(layerAt(f.plane)["name"].str == "Reference",  "T-S2b: the name came back");
    assertPlaneChannels(f.plane, "T-S2b");
    assertPose(f.plane, "T-S2b");
    auto lk = imageLink(f.plane);
    assert(lk.type != JSONType.null_
        && lk["target"].integer == cast(long) f.middleClip
        && lk["state"].str == "live",
        "T-S2b: the link resolves to the SAME clip after the reload — "
        ~ lk.toString);
}

// ===========================================================================
// T-S2c — the reader reads the FILE. Hand-mutate the saved document and load
// it; the values must follow the bytes.
//
// This is the case a round trip structurally cannot make. Save-then-load
// returns the right answer whenever the writer and the reader share a wrong
// convention, and it also returns the right answer when the loader keeps
// whatever the document already held. The mutation is to values that are
// non-default AND different from what this process ever set, so neither the
// defaults nor the pre-save state can produce them.
// ===========================================================================
unittest {
    auto f = buildFixture("mutated");
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(f.doc) ~ `}}`);

    auto j = parseJSON(readText(f.doc));
    j["layers"].array[f.plane]["channels"]["projection"] = JSONValue("bottom");
    j["layers"].array[f.plane]["channels"]["pixelSize"]  = JSONValue(0.123);
    j["layers"].array[f.plane]["channels"]["invert"]     = JSONValue(false);
    j["layers"].array[f.plane]["channels"]["keepAspect"] = JSONValue(true);
    write(f.doc, j.toString());

    resetCube();
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(f.doc) ~ `}}`);

    assert(attrS(f.plane, "projection") == "bottom",
        "T-S2c: the reader must take `projection` FROM THE FILE — 'right' "
        ~ "means it kept the pre-save value, 'front' means it took the "
        ~ "default. got " ~ attrS(f.plane, "projection"));
    assert(approx(attrF(f.plane, "pixelSize"), 0.123),
        format("T-S2c: pixelSize from the file — 0.037 means the pre-save "
             ~ "value, 0.01 means the default. got %.6f",
               attrF(f.plane, "pixelSize")));
    assert(attrB(f.plane, "invert") == false,
        "T-S2c: a channel mutated to its DEFAULT still has to be read — this "
        ~ "one is here so the case is not only about non-default values");
    assert(attrB(f.plane, "keepAspect") == true,
        "T-S2c: …and one mutated AWAY from what the fixture set, in the "
        ~ "direction the default also points, for the same reason");
}

// ===========================================================================
// T-S3 — the document moves to another folder.
//
// The plane must still bind the SAME clip (the link is an index into the
// document, so it travels with the document) and that clip must resolve into
// the NEW folder (the image path is stored relative to the document). `A/` is
// left standing on purpose: an implementation that stored the absolute image
// path resolves to a file that genuinely still exists and opens, so every
// "it is not missing" assertion passes it. The two copies differ in size, and
// the assertion is on the resolved DIRECTORY, which separates them exactly.
// ===========================================================================
unittest {
    auto root = scratch("moved");
    auto dirA = buildPath(root, "A");
    auto dirB = buildPath(root, "B");
    auto docA = buildPath(dirA, "scene.v3d");
    auto docB = buildPath(dirB, "scene.v3d");

    resetCube();
    foreach (i, nm; ["alpha.bmp", "bravo.bmp", "charlie.bmp"]) {
        bmpAt(buildPath(dirA, nm), cast(int)(3 + i), cast(int)(2 + i * 2));
        bmpAt(buildPath(dirB, nm), cast(int)(9 + i), cast(int)(4 + i * 2));
        cmd(`{"id":"image.load","path":` ~ jsonStr(buildPath(dirA, nm)) ~ `}`);
    }
    immutable size_t middle = 2;
    cmd(`{"id":"imagePlane.add","params":{"name":"Reference","projection":"front"}}`);
    immutable size_t plane = layerCount() - 1;
    cmd(format(`{"id":"imagePlane.setImage","params":{"index":%d,"image":%d}}`,
               plane, middle));
    writePlaneChannels(plane);
    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(docA) ~ `}}`);

    copy(docA, docB);
    resetCube();
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(docB) ~ `}}`);

    auto lk = imageLink(plane);
    assert(lk.type != JSONType.null_
        && lk["target"].integer == cast(long) middle
        && lk["state"].str == "live",
        "T-S3: after the move the plane binds the same clip index — a link "
        ~ "resolved by PATH would bind whichever clip the path matched, and "
        ~ "the three clips have three different paths so it would bind none. "
        ~ lk.toString);

    auto resolved = attrS(middle, "filename");
    assert(resolved.canFind(dirB),
        "T-S3: the clip must resolve into the NEW folder — an absolute stored "
        ~ "path resolves back into A/, where the file still exists and opens. "
        ~ "got " ~ resolved);
    assert(!resolved.canFind(dirA),
        "T-S3: …and specifically not into the old one. got " ~ resolved);

    // The plane's own channels came with it. Without this the case would be
    // about the image path only, and a move that dropped the payload again
    // would pass.
    assertPlaneChannels(plane, "T-S3");
}

// ===========================================================================
// THE ENUMERATION — every field of every kind, in one document, in one
// round trip. Not a sample: one layer of each of the four declared
// `ItemKind`s, every field the kind declares, plus the envelope fields that
// belong to no kind in particular.
//
// It is a separate case from T-S2 because it answers a different question.
// T-S2 asks "does the plane survive"; this asks "is the plane the only thing
// that does not", i.e. it is the control that stops the payload finding being
// read as a plane-specific quirk. A kind whose fields stop surviving reads its
// own name in the failure.
//
// NOT ASSERTED HERE, with the reason:
//   * `selected` / `primary` / `focused` — the loader RE-DERIVES the selection
//     through the document mutators rather than restoring it verbatim, so
//     these are `document.d`'s invariants, not round-trip fields.
//   * `mutationVersion` — a per-session counter, deliberately not persisted.
//   * `filename` on an image item — asserted by T-S3, where the interesting
//     question (which directory it resolves into) is actually observable.
// ===========================================================================
unittest {
    auto dir = scratch("enumerate");
    auto doc = buildPath(dir, "all_kinds.v3d");
    auto img = bmpAt(buildPath(dir, "kinds.bmp"), 5, 3);

    resetCube();
    cmd(`{"id":"image.load","path":` ~ jsonStr(img) ~ `}`);        // [1] image
    post(baseUrl ~ "/api/test/layer", `{"kind":"empty","name":"An Empty"}`); // [2]
    cmd(`{"id":"imagePlane.add","params":{"name":"A Plane","projection":"front"}}`); // [3]
    assert(layerCount() == 4, "fixture: one layer of every declared kind");
    assert(layerAt(0)["type"].str == "mesh"  && layerAt(1)["type"].str == "image"
        && layerAt(2)["type"].str == "empty" && layerAt(3)["type"].str == "imagePlane",
        "fixture: the four kinds, in a known order");

    // Envelope fields, per kind, all non-default and all DIFFERENT so a
    // cross-wiring lands on another layer's value rather than on its own.
    cmd(`layer.attr 0 name TheMesh`);
    cmd(`layer.attr 1 name TheClip`);
    cmd(`layer.attr 2 name TheEmpty`);
    cmd(`layer.attr 3 name ThePlane`);
    // The arg is `value`, NOT `visible` — `injectParamsInto` ignores an
    // unknown key, so the misspelling ran the command on its default `true`
    // and reported `ok`. Found here only because this case asserts the
    // OUTCOME rather than the status, which is the rule that exists for it.
    cmd(`{"id":"layer.setVisible","params":{"index":2,"value":false}}`);
    assert(layerAt(2)["visible"].boolean == false,
        "fixture: the hide actually took — a command that reports ok and "
        ~ "changes nothing would make the round-trip assertion below vacuous");
    cmd(`{"id":"layer.parent","params":{"child":3,"parent":2}}`);   // plane → empty

    // Kind-specific fields.
    cmd(`layer.attr 1 colorspace linear`);                          // image
    cmd(`layer.attr 1 useAlpha false`);
    writePose(2, /*second*/ true);                                   // empty: hasXform
    writePose(3);                                                    // plane: hasXform
    writePlaneChannels(3);                                           // plane: 10 channels
    cmd(`{"id":"imagePlane.setImage","params":{"index":3,"image":1}}`);
    immutable meshVerts = layerAt(0)["vertexCount"].integer;
    immutable meshFaces = layerAt(0)["faceCount"].integer;
    assert(meshVerts == 8 && meshFaces == 6, "fixture: the mesh payload is the cube");

    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(doc) ~ `}}`);
    resetCube();
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(doc) ~ `}}`);

    assert(layerCount() == 4, "ENUM: the layer COUNT survives");
    // --- envelope, every kind -------------------------------------------
    static immutable string[4] wantKind = ["mesh", "image", "empty", "imagePlane"];
    static immutable string[4] wantName = ["TheMesh", "TheClip", "TheEmpty", "ThePlane"];
    foreach (i; 0 .. 4) {
        assert(layerAt(i)["type"].str == wantKind[i],
            format("ENUM: layer %d kind — want %s got %s",
                   i, wantKind[i], layerAt(i)["type"].str));
        assert(layerAt(i)["name"].str == wantName[i],
            format("ENUM: layer %d name — want %s got %s",
                   i, wantName[i], layerAt(i)["name"].str));
    }
    assert(layerAt(2)["visible"].boolean == false,
        "ENUM: `visible` survives, and FALSE is the value that can fail — a "
        ~ "field never written reads the `true` default");
    assert(layerAt(0)["visible"].boolean && layerAt(1)["visible"].boolean
        && layerAt(3)["visible"].boolean,
        "ENUM: …and the other three stay visible, so the assertion above is "
        ~ "about layer 2 and not about a document-wide reset");
    assert(layerAt(3)["parent"].integer == 2,
        format("ENUM: `parent` survives, by index into the reloaded array — "
             ~ "got %d", layerAt(3)["parent"].integer));

    // --- mesh payload ----------------------------------------------------
    assert(layerAt(0)["vertexCount"].integer == meshVerts
        && layerAt(0)["faceCount"].integer   == meshFaces,
        "ENUM: the mesh payload survives");

    // --- image payload ---------------------------------------------------
    assert(attrS(1, "colorspace") == "linear", "ENUM: image.colorspace");
    assert(attrB(1, "useAlpha")   == false,    "ENUM: image.useAlpha");
    assert(attrS(1, "filename").length > 0,    "ENUM: image.filename is carried");

    // --- empty: the twelve transform components --------------------------
    assertPose(2, "ENUM/empty", /*second*/ true);

    // --- plane: ten channels, twelve components, one link ----------------
    assertPlaneChannels(3, "ENUM/plane");
    assertPose(3, "ENUM/plane");
    auto lk = imageLink(3);
    assert(lk.type != JSONType.null_ && lk["target"].integer == 1
        && lk["state"].str == "live", "ENUM: the plane's link — " ~ lk.toString);
}

// ===========================================================================
// T-S6 (tasks 0668 / 0671) — a document whose selected set and edit target
// name DIFFERENT items round-trips as such.
//
// WHY THIS ROW EXISTS, in two layers.
//
// 0654 taught the writer to emit `primaryLayer: -1` for "no mesh edit target"
// and taught the reader to answer it by CLEARING the selection outright,
// ignoring every per-layer `selected` bit, on the then-true ground that -1 and
// a selected layer could not both occur. 0668 made them occur together on the
// most ordinary path there is: create a reference plane.
//
// 0671 changed WHICH disagreement this row carries, and made it a harder one.
// Creating a plane no longer clears the edit target — the mesh is deselected
// into the mesh history bucket and stays the target — so what gets saved is a
// file whose `primaryLayer` names an item its own `selected` says is FALSE.
// A reader that re-selects the item `primaryLayer` names round-trips the
// document into a different one, silently, with the panel showing a selection
// the user never left behind.
//
// The wrong implementations and their readings:
//   * the reader re-SELECTS the item `primaryLayer` names  -> `selected [0,1]`
//     after the load, where the file said `[1]`;
//   * the reader treats an unselected `primaryLayer` as no target  -> `primary
//     []` / `active -1`, losing the latch the file recorded;
//   * the reader keeps 0654's `clearItemSelection()`-and-stop  -> `selected []`
//     and `focused -1`;
//   * the writer emits the wrong `primaryLayer`  -> the same readings as
//     above, and the FILE assertions below are what tell writer from reader.
// ===========================================================================
unittest {
    int[] selectedIndices() {
        int[] r;
        foreach (i, l; getLayers()["layers"].array)
            if (l["selected"].boolean) r ~= cast(int) i;
        return r;
    }
    int[] primaryIndices() {
        int[] r;
        foreach (i, l; getLayers()["layers"].array)
            if (l["primary"].boolean) r ~= cast(int) i;
        return r;
    }
    int focusedIndex() {
        foreach (i, l; getLayers()["layers"].array)
            if (l["focused"].boolean) return cast(int) i;
        return -1;
    }
    int activeIndex() { return cast(int) getLayers()["active"].integer; }

    auto dir  = scratch("noprimary");
    auto path = buildPath(dir, "plane_alone.v3d");

    resetCube();
    cmd(`{"id":"imagePlane.add","params":{"name":"Lone Plane"}}`);
    assert(layerCount() == 2, "fixture: the cube and one plane");
    assert(selectedIndices() == [1] && primaryIndices() == [0],
        "fixture (task 0671): the plane alone in the SELECTION, the mesh still "
        ~ "the EDIT TARGET — read selected " ~ selectedIndices().to!string
        ~ " primary " ~ primaryIndices().to!string);

    cmd(`{"id":"file.save","params":{"path":` ~ jsonStr(path) ~ `}}`);

    // The FILE, read as bytes. Distinguishes a writer defect from a reader
    // defect before either is blamed.
    auto onDisk = parseJSON(readText(path));
    assert(onDisk["primaryLayer"].integer == 0,
        "the file records the LATCHED edit target as its index, read "
        ~ onDisk["primaryLayer"].integer.to!string);
    assert(onDisk["layers"].array[1]["selected"].boolean,
        "…and records the plane as SELECTED");
    assert(!onDisk["layers"].array[0]["selected"].boolean,
        "…and the mesh as NOT selected, which is the disagreement this row is "
        ~ "about: `primaryLayer` names an item the file does not mark selected");
    assert(onDisk["focusedItem"].integer == 1,
        "…and names the plane as the focus, read "
        ~ onDisk["focusedItem"].integer.to!string);

    resetCube();
    assert(primaryIndices() == [0] && selectedIndices() == [0],
        "control: the reset document has the mesh both selected AND the target, "
        ~ "so the load has both columns to change");
    cmd(`{"id":"file.load","params":{"path":` ~ jsonStr(path) ~ `}}`);

    assert(layerCount() == 2, "the load restored both items");
    assert(selectedIndices() == [1],
        "the plane comes back as the ONLY selected item. `[]` is the 0654 "
        ~ "reader (selection dropped); `[0,1]` or `[0]` is a reader that "
        ~ "repaired the absent primary. Read " ~ selectedIndices().to!string);
    assert(primaryIndices() == [0] && activeIndex() == 0,
        "…and the LATCHED edit target came back on the mesh, read primary "
        ~ primaryIndices().to!string ~ " active " ~ activeIndex().to!string);
    assert(!getLayers()["layers"].array[0]["selected"].boolean,
        "…without re-selecting it: a reader that installs the target by "
        ~ "SELECTING it round-trips this document into a different one");
    assert(getLayers()["layers"].array[0]["foreground"].boolean,
        "…and it reads FOREGROUND, so what came back is the state that was "
        ~ "saved and not merely the same index");
    assert(focusedIndex() == 1,
        "…and the plane holds the focus, read " ~ focusedIndex().to!string);
    assert(layerAt(1)["type"].str == "imagePlane",
        "sanity: the surviving selected row really is the plane");
}
