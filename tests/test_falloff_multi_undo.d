// test_falloff_multi_undo.d — SET-AWARE in-session falloff re-grade undo/refire
// across a STACKED multi-falloff set (Phase 3 of
// doc/falloff_multi_subtool_plan.md, second half).
//
// The single-falloff in-session re-grade undo/refire is covered by
// test_falloff_refire_rs.d. This file pins the SET-AWARE extension: with TWO
// active falloff instances stacked at runtime (`falloff.add radial`), the
// transform wrapper's gesture-commit + refire config-restore hooks must
// snapshot / restore the WHOLE active set, and the wrapper's live-change trigger
// must fire on a change to ANY instance — not just the primary.
//
// What this asserts (mirrors the test_falloff_refire_rs contracts, across the
// SET):
//   • two falloffs stacked (`falloff` + `falloff#1`), a Rotate gesture lands
//     ONE tagged in-session entry;
//   • CHANGING the SECONDARY falloff's config (`falloff#1 size`) at idle
//     re-grades the landed gesture against the new COMBINED weight and APPENDS
//     ONE tagged in-session entry (run +1, not +N);
//   • ONE in-session Ctrl+Z reverts ONLY that re-grade (geometry back to the
//     post-gesture state) AND restores `falloff#1`'s config to its PRE-tweak
//     value — while the PRIMARY `falloff`'s config is UNTOUCHED throughout
//     (the set-aware restore targets the right instance by identity);
//   • the drop consolidates the run to ONE entry; one post-drop Ctrl+Z reverts
//     the whole run to the cube.
//
// A second case drives the same shape by tweaking the PRIMARY while a secondary
// is stacked, asserting the secondary's config is the untouched one — proving
// restore is keyed to the changed instance, not blindly to the primary.
//
// Test discipline (CLAUDE.md + the refire template): drainHistory BEFORE
// /api/reset; in-session Ctrl+Z is the navHistory keystroke (never /api/undo);
// vec3 falloff attrs are DOUBLE-QUOTED; a ~120ms settle follows every
// play-events + config command; counts are truthful with timeline comments.
// falloff.clear runs at teardown so the next test sees the byte-stable single
// WGHT-stage baseline.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, PI;
import std.conv : to;
import std.string : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }

long inSessionCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("inSession" in e.object) !is null && e["inSession"].boolean) ++n;
    return n;
}

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(120.msecs);
}

void drainHistory() {
    foreach (_; 0 .. 100) {
        if (undoCount() == 0) return;
        postJson("/api/undo", "");
    }
}

// Pristine cube + EMPTY undo stack + NO stacked falloff extras. Mirrors the
// refire template's establishCubeBaseline, plus a falloff.clear so a prior
// test's stacked instances never bleed into this one's WGHT-stage set.
void establishCubeBaseline() {
    import core.thread : Thread;
    import core.time   : msecs;
    bool playerIdle() {
        auto s = getJson("/api/play-events/status");
        auto f = "finished" in s;
        return f is null || f.type != JSONType.false_;
    }
    bool cubePristine() {
        auto v = getJson("/api/model")["vertices"].array;
        if (v.length != 8) return false;
        auto c = v[6].array;
        return fabs(c[0].floating - 0.5) < 1e-3
            && fabs(c[1].floating - 0.5) < 1e-3
            && fabs(c[2].floating - 0.5) < 1e-3;
    }
    foreach (attempt; 0 .. 8) {
        postJson("/api/script", "tool.set move off");
        postJson("/api/script", "tool.set TransformScale off");
        postJson("/api/script", "tool.set TransformRotate off");
        postJson("/api/script", "tool.set Transform off");
        foreach (_; 0 .. 200) {
            if (playerIdle()) break;
            Thread.sleep(10.msecs);
        }
        Thread.sleep(120.msecs);
        postJson("/api/reset", "");
        postJson("/api/command", "falloff.clear");      // drop stacked extras
        postJson("/api/command", "history.clear");      // wipe stacks, keep cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
    postJson("/api/command", "falloff.clear");
    postJson("/api/command", "history.clear");
    assert(cubePristine(), "could not establish pristine cube baseline");
}

double[3] vert(int idx) {
    auto v = getJson("/api/model")["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVertex(int idx, double x, double y, double z, string label) {
    auto v = vert(idx);
    assert(fabs(v[0]-x) < 1e-3 && fabs(v[1]-y) < 1e-3 && fabs(v[2]-z) < 1e-3,
        label ~ ": v" ~ idx.to!string ~ " expected (" ~ x.to!string ~ ","
        ~ y.to!string ~ "," ~ z.to!string ~ "), got (" ~ v[0].to!string ~ ","
        ~ v[1].to!string ~ "," ~ v[2].to!string ~ ")");
}

bool vertNear(double[3] a, double[3] b, double eps = 1e-3) {
    return fabs(a[0]-b[0]) < eps && fabs(a[1]-b[1]) < eps && fabs(a[2]-b[2]) < eps;
}

string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

double[3] rotateGestureOnRing(long wantCount, int sweep = 25) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        int xa, ya;
        ringGrabPx(evalPivot(), vp, xa, ya);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xa + sweep, ya + sweep, 10));
        settle();
        if (undoCount() == wantCount) break;
    }
    return vert(6);
}

// The `size` X attr of a WGHT stage by id, read from /api/toolpipe (the live
// stage attrs dict). This is the per-instance config witness: after an
// in-session Ctrl+Z of a re-grade driven by `id`'s tweak, `id`'s size must
// revert to its PRE-tweak value (the set-aware restore hit the right instance);
// the OTHER instance's size must be unchanged throughout.
double wghtSizeX(string id) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT" && st["id"].str == id) {
            // size attr is "x,y,z"; parse the X component.
            auto s = st["attrs"]["size"].str;
            import std.string : split;
            return s.split(",")[0].to!double;
        }
    }
    assert(false, "WGHT stage '" ~ id ~ "' has no size attr in /api/toolpipe");
}

// Stack TWO radial falloffs centred on v6, both TIGHT. The primary is the
// re-grade witness driver in case 1; falloff#1 is the secondary. Both must be
// radial so `size` is exposed.
void configTwoTightRadials() {
    // primary
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);
    // secondary (stacked) — additive so widening it pulls more of the mesh in
    cmd("falloff.add radial");
    cmd("tool.pipe.attr falloff#1 shape linear");
    cmd(`tool.pipe.attr falloff#1 center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff#1 size "1,1,1"`);
    cmd("tool.pipe.attr falloff#1 mix add");
}

// ===========================================================================
// (SECONDARY-REGRADE) Tweak the SECONDARY falloff → set-aware re-grade + undo.
//
// timeline: tool.set TransformRotate → two tight radials → ring gesture
//   (1 entry) → WIDEN falloff#1 (re-grade: the COMBINED weight changes → v0
//   pulled along; APPEND → inSession 2) → assert geometry re-graded + counts +
//   the PRIMARY config untouched → in-session Ctrl+Z (revert ONLY the re-grade:
//   geometry back to post-gesture AND falloff#1 size restored to its pre-tweak
//   value, PRIMARY still untouched) → drop → ONE entry → post-drop Ctrl+Z → cube.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTwoTightRadials();
    settle();

    // Pre-condition: exactly the primary + one stacked secondary, both size 1.
    auto primSize0 = wghtSizeX("falloff");
    auto secSize0  = wghtSizeX("falloff#1");
    assert(fabs(primSize0 - 1.0) < 1e-3 && fabs(secSize0 - 1.0) < 1e-3,
        "both falloffs start at size 1; prim=" ~ primSize0.to!string
        ~ " sec=" ~ secSize0.to!string);

    long floor = undoCount();

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");
    assert(inSessionCount() == 1, "one rotate gesture tagged inSession");
    auto v0AfterG = vert(0);   // far corner: barely rotated under the tight set

    // WIDEN the SECONDARY radius → the COMBINED (add-mixed) weight grows, so the
    // landed rotation re-grades at idle, baking ONE appended in-session entry.
    cmd(`tool.pipe.attr falloff#1 size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "a SECONDARY-falloff re-grade APPENDS one tagged in-session entry "
        ~ "(gesture + re-grade); got " ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "the CONFIG command records nothing; only the re-grade added an entry "
        ~ "(floor+2); floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the SECONDARY re-grade MUST mutate geometry at idle (set-aware combined "
        ~ "weight changed): v0 post-gesture (" ~ v0AfterG[0].to!string ~ ","
        ~ v0AfterG[1].to!string ~ "," ~ v0AfterG[2].to!string ~ ") re-graded ("
        ~ v0Regraded[0].to!string ~ "," ~ v0Regraded[1].to!string ~ ","
        ~ v0Regraded[2].to!string ~ ")");

    // The PRIMARY config is UNTOUCHED by the secondary tweak.
    assert(fabs(wghtSizeX("falloff") - primSize0) < 1e-3,
        "the SECONDARY tweak left the PRIMARY config untouched; prim size was "
        ~ primSize0.to!string ~ " now " ~ wghtSizeX("falloff").to!string);
    assert(fabs(wghtSizeX("falloff#1") - 5.0) < 1e-3,
        "the SECONDARY size took the tweak (5); got "
        ~ wghtSizeX("falloff#1").to!string);

    // One in-session Ctrl+Z reverts ONLY the re-grade: geometry back to the
    // post-gesture state AND the SECONDARY config restored to its PRE-tweak
    // value (set-aware restore targets falloff#1 by identity); the PRIMARY stays
    // untouched.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the secondary re-grade to the post-gesture "
        ~ "geometry; v0 expected (" ~ v0AfterG[0].to!string ~ ","
        ~ v0AfterG[1].to!string ~ "," ~ v0AfterG[2].to!string ~ ") got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(fabs(wghtSizeX("falloff#1") - secSize0) < 1e-3,
        "the set-aware in-session Ctrl+Z RESTORED falloff#1's config to its "
        ~ "PRE-tweak size (1); got " ~ wghtSizeX("falloff#1").to!string);
    assert(fabs(wghtSizeX("falloff") - primSize0) < 1e-3,
        "the PRIMARY config is STILL untouched after the undo; got "
        ~ wghtSizeX("falloff").to!string);
    assert(undoCount() == floor + 1,
        "after the in-session Ctrl+Z the run holds the lone rotate gesture "
        ~ "(floor+1); now=" ~ undoCount().to!string);

    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop leaves ONE entry (the surviving rotate gesture); now="
        ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated rotate run to the cube");
    cmd("falloff.clear");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (PRIMARY-REGRADE) Tweak the PRIMARY while a secondary is stacked → the
// SECONDARY is the untouched one.
//
// Symmetric witness to case 1: the tweak drives the PRIMARY; the set-aware
// restore must put the PRIMARY back on undo while leaving falloff#1 untouched.
// This proves the restore is keyed to the CHANGED instance, not blindly to the
// primary index.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTwoTightRadials();
    settle();

    auto primSize0 = wghtSizeX("falloff");
    auto secSize0  = wghtSizeX("falloff#1");
    long floor = undoCount();

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");
    auto v0AfterG = vert(0);

    // WIDEN the PRIMARY radius → combined weight grows → re-grade APPENDS.
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "a PRIMARY-falloff re-grade APPENDS one tagged in-session entry; got "
        ~ inSessionCount().to!string);
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the PRIMARY re-grade mutated geometry at idle");
    // The SECONDARY config is untouched by the primary tweak.
    assert(fabs(wghtSizeX("falloff#1") - secSize0) < 1e-3,
        "the PRIMARY tweak left the SECONDARY config untouched; got "
        ~ wghtSizeX("falloff#1").to!string);

    // In-session Ctrl+Z restores the PRIMARY config + geometry; SECONDARY stays.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the primary re-grade geometry to post-gesture");
    assert(fabs(wghtSizeX("falloff") - primSize0) < 1e-3,
        "the set-aware in-session Ctrl+Z RESTORED the PRIMARY config to its "
        ~ "PRE-tweak size (1); got " ~ wghtSizeX("falloff").to!string);
    assert(fabs(wghtSizeX("falloff#1") - secSize0) < 1e-3,
        "the SECONDARY config is STILL untouched after the undo; got "
        ~ wghtSizeX("falloff#1").to!string);

    cmd("tool.set TransformRotate off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated rotate run to the cube");
    cmd("falloff.clear");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}
