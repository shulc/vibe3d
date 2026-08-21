// Task 1521 — the BEHAVIOURAL census of "which commands throw the document
// away", checked against what each one DECLARES.
//
// WHY BEHAVIOURAL AND NOT A LIST OF NAMES. A gate keyed on `file.` / `scene.`
// prefixes is exactly the thing the plan rejects on its first page: it passes
// the day someone adds a fifth discard path under a fifth name. This runs every
// registered command from TWO DIFFERENT starting documents and asks whether the
// results agree. Agreement means the output does not depend on the input, which
// means the input was thrown away.
//
// THE OBVIOUS ALTERNATIVE IS REFUTED, and it is worth writing down because it
// is the one a reader will reach for. "Did the `Layer` object / the `Mesh*`
// change?" cannot work for the MAIN command: `SceneReset` KEEPS the primary
// `Layer` (`auto keep = document.primary` → `document.layers = [ keep ]`) and
// writes the mesh THROUGH the existing pointer (`*mesh = Mesh.init`). On a
// one-layer document neither identity moves, so `file.new` would be
// indistinguishable from `mesh.subdivide` — a gate that goes green on precisely
// the hole it exists to catch.
//
// TWO MEASURED CORRECTIONS to the criterion, both found by running it:
//
//   1. THE SIGNATURE IS THE WHOLE DOCUMENT, not `/api/model` (the primary
//      layer). With the primary alone, `layer.add` reads as a discard: it makes
//      a NEW EMPTY layer primary, so the primary's mesh is empty whatever the
//      document held. Nothing was thrown away — the instrument was looking at
//      the wrong thing.
//
//   2. A SELECTION IS SEEDED FIRST. This codebase's "empty selection ⇒ operate
//      on the whole mesh" convention meant `mesh.delete` / `mesh.remove` /
//      `select.delete` / `select.remove` deleted EVERYTHING and so read as
//      input-independent. Driving a command into its operate-on-everything
//      fallback measures the fallback, not the policy. With one vertex
//      selected, all four correctly depend on their input.
//
// THE ONLY REMAINING LIST IS HARNESS LIMITS, NOT POLICY EXCEPTIONS — a newly
// registered command lands in the census BY DEFAULT (fail-closed). Each entry
// carries the reason it cannot be fired blind, and each was measured.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : mkdirRecurse, exists, remove;
import std.path   : buildPath;
import std.digest.sha : sha1Of, toHexString;
import std.algorithm : startsWith, canFind, sort;
import std.array   : array;
import std.process : thisProcessID;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

string postRaw(string path, string body_) {
    return cast(string)post(baseUrl ~ path, body_);
}

void resetTo(string query) { postRaw("/api/reset" ~ query, ""); }

/// One vertex selected — see correction (2) in the header.
void seedSelection() {
    postRaw("/api/select", `{"mode":"vertices","indices":[0]}`);
}

/// The WHOLE document — every layer's vertices and faces — see correction (1).
///
/// `vertices` and `faces` ONLY, and that is load-bearing: `/api/model` also
/// carries a `timestamp`, which differs on every call. Hashing the whole body
/// makes EVERY command look input-dependent, so the census reports nothing as
/// a discard and every declaration as unhonoured — measured, and it is why
/// this reads two named fields instead of the payload.
string documentSignature() {
    auto layers = getJson("/api/layers")["layers"].array;
    string acc;
    foreach (i, l; layers) {
        // A non-mesh item (an image, an image plane) answers with no geometry
        // keys at all; its NAME and KIND still belong in the signature, because
        // adding one is a document change the census must see as such.
        acc ~= l["type"].toString ~ l["name"].toString ~ "#";
        auto m = getJson("/api/model?layer=" ~ i.to!string);
        acc ~= (("vertices" in m.object) ? m["vertices"].toString : "-")
             ~ "#"
             ~ (("faces" in m.object) ? m["faces"].toString : "-") ~ "|";
    }
    return sha1Of(acc).toHexString.idup;
}

string fireCommand(string id, string paramsJson) {
    string body_ = paramsJson.length
        ? `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`
        : id;
    auto r = parseJSON(postRaw("/api/command", body_));
    return r["status"].str;
}

// ---------------------------------------------------------------------------
// HARNESS LIMITS — what the census cannot fire blind, and why. MEASURED, not
// assumed. This is not a list of commands exempt from the POLICY: a command
// here is one the instrument cannot drive, and every one of them still has to
// be covered by an assertion somewhere else (`file.quit` is, by
// tests/test_unsaved_guard.d's `guardsQuit`).
// ---------------------------------------------------------------------------
immutable string[] kSkipPrefixes = [
    // `undo.lockout.` — a TEST-AUTOMATION switch that turns history recording
    // OFF for the life of the instance (`registration.d`, `history.setLockout`).
    // Firing it is not a document discard, it is a service outage: after it,
    // every later command records nothing and every undo answers "stack empty".
    // `/api/reset` does NOT clear it.
    //
    // MEASURED, twice, on 2026-08-19: this census fired it and every test that
    // ran afterwards ON THE SAME WORKER failed -- 8 on CI, 27 on the sanitizer
    // lane -- with "expected +1 entry, got +0", "expected 3 entries; got 0",
    // "stack empty or revert failed". None of them was a defect of its own;
    // they were all reading a poisoned instance, because the runner reuses one
    // editor for every test a worker takes.
    "undo.lockout.",
    // `ui.*` — the --test-only PANEL VISIBILITY toggles (`ui.statistics`,
    // `ui.layerList`, `ui.channels`, `ui.imageList`, `ui.viewportProps`,
    // `ui.toolProperties`, `ui.about`, and `ui.statistics.expand`). Same class
    // as `undo.lockout.` above and not a document discard either: each one
    // writes a single `__gshared bool` that no signature can see, so the census
    // can never learn anything from firing them.
    //
    // What it DOES learn is a floating window. The argument-less form these are
    // fired with never calls `setVisible`, so `apply()` publishes the command
    // object's FIELD DEFAULT — and every one of them declares
    // `private bool show_ = true`. A census pass therefore leaves EVERY panel
    // OPEN on the instance the runner shares across a whole worker slice, and
    // `/api/reset` does not close them. `tests/test_app_version.d` already
    // states the hazard in as many words for its own window ("MUST leave the
    // window hidden: it is a floating window, and one left open would sit over
    // the viewport for every later test in this worker's slice"); this sweep
    // opened seven of them.
    //
    // MEASURED (CI 32303254597 / 32340597743 / 32342721835 / 32353119894 /
    // 32358311256 / 32415544322, six runs, `test_draw_alloc_scaling` red in all
    // six with a byte-identical delta of 68272 B/frame). An OPEN Statistics
    // panel rebuilds its row model every frame, and with the `Vertices/By Edge`
    // category expanded that rebuild calls `Mesh.vertexEdgeCounts()` — one
    // `new uint[V]` per frame, i.e. an allocation PROPORTIONAL TO THE MESH on
    // the frame path, which is exactly what that test exists to forbid. The
    // expand state comes from `test_stat_panel_rows` earlier in the same slice:
    // that test closes the panel it opened but the expand bits live on in
    // `g_statExpand`, invisible until something re-opens the panel. This census
    // was that something. Reproduced end to end on a dev box by running
    // `test_stat_panel_rows` -> `test_discard_census` -> `test_draw_alloc_scaling`
    // against one instance: 6288 -> 6288 B/frame clean, 129040 -> 197312 after,
    // the same 68272 delta the runner reports.
    "ui.",
    // `selftest.*` — the deliberate-defect injector (task 1410). It is NOT in
    // the shipping binary: it is registered only where `SanitizerSelfTest` is
    // declared, i.e. the four instrumented buildTypes. So in every ordinary
    // run this census never sees it, which is exactly why it was missed here.
    //
    // Under `--build=check` it IS registered, and its whole purpose is to
    // injure the process on purpose: `selftest.fault` asserts, and that build
    // carries `--checkaction=C`, which turns a failed assert into an immediate
    // abort. The census fires every registered command, so it fired this one
    // and killed the editor mid-suite. MEASURED, on the sanitizer lane's first
    // complete night: the core dump's thread 1 is
    // `selftest_fault.SelfTestFaultCommand.apply` -> `__assert_fail` -> abort,
    // reached through `dispatchCommandLine`; 31 tests then failed on that
    // worker with "could not connect", every one of them a corpse-read rather
    // than a defect of its own.
    //
    // Task 1412's fuzz policy already excludes the same prefix for the same
    // reason, in its own words ("its purpose is to injure the process on
    // purpose"). Two sweeps over one registry, written the same day; one
    // author foresaw the injector because the fuzzer runs against instrumented
    // builds, the other could not because the ordinary build hides it.
    "selftest.",
    // Submits work to the ai3d worker (network + a subprocess); a census pass
    // would leave jobs running against the shared --test instance.
    "ai3d.",
    // Writes macro script files to disk.
    "macro.",
];

immutable string[] kSkipExact = [
    // Spawns the quad-remesher subprocess.
    "mesh.remesh",
    // MEASURED LIMIT, not an exemption: quitting discards unsaved work, but it
    // discards nothing the census's instrument (the document) can see, so it
    // can only ever read as "input-dependent" and would fail the declaration
    // side forever. Its guard is pinned directly by
    // tests/test_unsaved_guard.d::guardsQuit.
    "file.quit",
];

// ---------------------------------------------------------------------------
// SEEDS — the few commands that need an argument to do their job at all. A
// MISSING seed does not go quiet: the declaration side fails with "declared but
// never observed discarding", which is the whole point of checking BOTH
// directions.
// ---------------------------------------------------------------------------
string[string] buildSeeds() {
    const dir = buildPath("/tmp", "vibe3d_discard_census_" ~ thisProcessID.to!string);
    mkdirRecurse(dir);
    // The seeds are produced by EXPORTING the current scene, so the census
    // never depends on a checked-in binary fixture that could rot.
    resetTo("");
    string mk(string cmd, string ext) {
        const p = buildPath(dir, "seed" ~ ext);
        auto st = fireCommand(cmd, `{"path":"` ~ p ~ `"}`);
        assert(st == "ok", "census setup: " ~ cmd ~ " -> " ~ p ~ " failed");
        assert(exists(p), "census setup: " ~ cmd ~ " wrote nothing to " ~ p);
        return p;
    }
    const v3d  = mk("file.save",        ".v3d");
    const obj  = mk("file.export.obj",  ".obj");
    const lwo  = mk("file.export.lwo",  ".lwo");
    const gltf = mk("file.export.gltf", ".gltf");
    const fbx  = mk("file.export.fbx",  ".fbx");
    string[string] seeds;
    seeds["file.load"]        = `{"path":"` ~ v3d  ~ `"}`;
    seeds["file.open"]        = `{"path":"` ~ v3d  ~ `"}`;
    seeds["file.import.obj"]  = `{"path":"` ~ obj  ~ `"}`;
    seeds["file.import.lwo"]  = `{"path":"` ~ lwo  ~ `"}`;
    seeds["file.import.gltf"] = `{"path":"` ~ gltf ~ `"}`;
    seeds["file.import.fbx"]  = `{"path":"` ~ fbx  ~ `"}`;
    return seeds;
}

bool skipped(string id) {
    foreach (p; kSkipPrefixes) if (id.startsWith(p)) return true;
    foreach (e; kSkipExact)    if (id == e)          return true;
    return false;
}

unittest { // THE CENSUS, both directions
    auto seeds = buildSeeds();

    auto reg       = getJson("/api/registry");
    auto ids       = reg["commands"].array;
    bool[string] declared;
    foreach (d; reg["commandsDiscardingWork"].array) declared[d.str] = true;
    assert(declared.length >= 4,
        "the registry publishes no discard declarations at all — the census "
        ~ "would then be measuring nothing on the declaration side");

    string[] undeclared;    // behaves like a discard, says nothing
    string[] unobserved;    // says it discards, could not be made to
    size_t   swept;

    foreach (idv; ids) {
        const id = idv.str;
        if (skipped(id)) continue;
        const args = (id in seeds) ? seeds[id] : "";

        resetTo("");                            // start A: a cube
        seedSelection();
        fireCommand(id, args);
        const a = documentSignature();

        resetTo("?type=subdivcube&levels=2");   // start B: a 98-vertex mesh
        seedSelection();
        fireCommand(id, args);
        const b = documentSignature();

        swept++;
        const observed = (a == b);              // output independent of input
        const decl     = (id in declared) !is null;
        if (observed && !decl) undeclared ~= id;
        if (!observed && decl) unobserved ~= id;
    }
    resetTo("");

    // The teardown that catches the NEXT one. Excluding the two ids above
    // fixes the two we know about; this fixes the class. A registry sweep can
    // fire anything the registry publishes, including a service switch that
    // outlives the sweep -- so the census asserts, on its way out, that it
    // left the history service in the state it found it. Without this the
    // damage is invisible here and lands on whichever unrelated test the
    // runner happens to schedule next, which is exactly how the two above
    // presented: as eight and twenty-seven failures with no common subject.
    {
        const st = getJson("/api/undo/status");
        assert(!st["lockout"].boolean,
            "the census left the history service LOCKED OUT — some command it "
            ~ "fired engaged `history.setLockout` and nothing released it. "
            ~ "Every test scheduled after this one on the same worker will now "
            ~ "record nothing and fail on an empty undo stack. Add the id to "
            ~ "kSkipPrefixes / kSkipExact, or release it here.");
    }

    // The SECOND teardown of the same shape, and it is here because the first
    // one's own words came true: "a registry sweep can fire anything the
    // registry publishes, including a service switch that outlives the sweep".
    // The switch that got out the second time was PANEL VISIBILITY. It cost six
    // CI runs (32303254597 .. 32415544322) before anyone read the floor of the
    // number that went red, and it presented exactly as the lockout did — as a
    // failure in an unrelated test, with a message pointing somewhere else.
    //
    // `statRebuilds` is the instrument because it is the one that MEASURES the
    // damage rather than the state: it counts Statistics-panel row-model
    // rebuilds, which happen only while that panel is drawing, and an open
    // Statistics panel is the one whose per-frame cost is PROPORTIONAL TO THE
    // MESH (`buildStatContext` -> `Mesh.vertexEdgeCounts`, a `new uint[V]` per
    // frame whenever a category needing a derived array is expanded). That is
    // what `tests/test_draw_alloc_scaling.d` exists to forbid, and what it kept
    // reporting from this instance.
    //
    // Both numbers are read from the SAME window — the one that opens at the
    // counter reset — so that the zero MEANS something: a frozen editor also
    // rebuilds nothing, and this assertion must not pass for that reason. The
    // frame count is therefore read AFTER the reset, not across it: the reset
    // zeroes `frames` too, so a before/after comparison reads as a counter
    // running BACKWARDS and fails on a perfectly live editor (measured, first
    // run of this block: "14020 -> 91").
    {
        import core.thread : Thread;
        import core.time   : msecs;
        postRaw("/api/frames/counts/reset", "{}");
        Thread.sleep(400.msecs);
        const counts        = getJson("/api/frames/counts");
        const long drawn    = counts["frames"].integer;
        const long rebuilds = counts["totals"]["statRebuilds"].integer;
        assert(drawn > 0,
            "the census teardown could not take a reading: no frame was "
            ~ "committed in the 400 ms after the counter reset. A zero below "
            ~ "would then be a frozen editor, not a closed panel.");
        assert(rebuilds == 0,
            "the census left a PANEL OPEN — the Statistics panel rebuilt its "
            ~ "row model " ~ rebuilds.to!string ~ " times in the 400 ms after "
            ~ "the sweep, so it is drawing. `/api/reset` does not close a "
            ~ "floating window, so every test scheduled after this one on the "
            ~ "same worker gets a viewport with a window over it and a frame "
            ~ "that allocates in proportion to the mesh. The argument-less form "
            ~ "of a `ui.*` toggle publishes the command object's field default, "
            ~ "which is `show_ = true`; that is why `\"ui.\"` is in "
            ~ "kSkipPrefixes. If a new visibility switch escaped the sweep, add "
            ~ "it there or close it here.");
    }

    assert(swept > 200,
        "the census swept only " ~ swept.to!string ~ " commands — a sweep that "
        ~ "covers almost nothing passes trivially");

    assert(undeclared.length == 0,
        "UNDECLARED DISCARD: these commands produce the same document from two "
        ~ "different starting documents — they threw the work away — but do not "
        ~ "declare `Command.discardsUnsavedWork`, so the guard never sees them: "
        ~ undeclared.sort.array.to!string);

    assert(unobserved.length == 0,
        "DECLARED BUT NEVER OBSERVED DISCARDING: these declare "
        ~ "`Command.discardsUnsavedWork` but the census could not make them do "
        ~ "it — almost always a MISSING SEED (a `file.load` with no path is a "
        ~ "no-op). Add the argument to buildSeeds(), do not remove the "
        ~ "declaration: " ~ unobserved.sort.array.to!string);
}
