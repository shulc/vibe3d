// test_falloff_refire_rs.d — falloff in-session re-fire EDGE-CASE suite.
//
// Phase 2 (Rotate / Scale re-grade sites) + Phase 3 (edge-case coverage) of the
// falloff in-session re-fire feature. The Move bank's F-mirror / REPLACE /
// pop-then-tweak / multi-gesture cases live in test_run_consolidation.d (cases
// D / D2 / D3 / D4); this file mirrors them for the ROTATE and SCALE banks and
// adds the Phase-3 edge cases the plan enumerates:
//
//   R/S F-MIRROR    — a falloff change at idle after a committed R/S gizmo
//                     gesture re-grades that gesture's geometry against the new
//                     weights and bakes ONE tagged in-session entry in the SAME
//                     run; one in-session Ctrl+Z reverts ONLY the re-grade; the
//                     drop consolidates to ONE entry (contracts A/C/D).
//   R/S REPLACE     — consecutive tweaks REPLACE the prior re-grade (run stays
//                     +1, not +N) with a widening support reverting cleanly.
//   R/S MULTI-RUN   — case-D4 analogue: the REPLACE-vs-APPEND key is "is the tail
//                     a refire", so g1→tweak1→g2→tweak2→tweak3 = FOUR entries and
//                     g2 survives the merge (anchor/stamp wiring at the R/S
//                     commit sites).
//   R/S ZERO-GEST   — a falloff change with NO gesture landed is inert.
//   FALLOFF SWITCH  — switching falloff TYPE mid-run (not just a param tweak)
//                     is a packet inequality → it re-grades (one entry).
//   FALLOFF OFF     — turning falloff OFF mid-run re-grades to weight=1
//                     everywhere (the implemented `type none` semantics).
//   SEL BOUNDARY    — a falloff change AFTER a selection boundary is inert
//                     (the run closed; edge 4).
//   SYMMETRY        — a symmetric re-grade moves the mirrored set consistently.
//   DEGENERATE      — pop gesture → tweak → drop = ONE consolidated entry (the
//                     surviving gesture; n==1 strips both the inSession AND
//                     refire bits); asserted via /api/history's refire field.
//   OBJ-2 SANITY    — a composed-preset Move-then-Rotate sequence is TWO runs
//                     (bank switch = boundary); a post-Rotate falloff tweak
//                     re-grades only the Rotate run.
//
// Test discipline (CLAUDE.md + plan §8): selectV6() does NOT drain its select
// entry; drainHistory() runs BEFORE /api/reset (reset is itself undoable); the
// in-session Ctrl+Z is ALWAYS the navHistory keystroke, NEVER /api/undo (which
// is raw history.undo() with no resyncSession); vec3 falloff attrs are
// DOUBLE-QUOTED; verify-and-retry is keyed on the UNDO COUNT; a ~120ms settle
// follows every play-events + config command; counts are truthful with timeline
// comments. R3 (CLOSED by P-A): an in-session Ctrl+Z of a falloff re-grade now
// restores the falloff CONFIG together with the geometry — the re-grade entry
// carries config-restore hooks (revert→PRE-tweak packet, apply→POST-tweak
// packet) so the visible handle reverts WITH the mesh and redo re-applies both.
// The (CONFIG-RESTORE) cases below assert this on the Move, Rotate, and Scale
// banks. (Previously R3 was an accepted v1 divergence: config stayed at the new
// value across an in-session undo.)

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
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: "
        ~ r.toString);
}

// Drive a CONTINUOUS pipe scrub: a sequence of tool.pipe.attr writes that SHARE
// one tweak generation (the headless analogue of a held falloff-handle / slider
// drag). /api/script?interactive=true raises the app's formsInteractiveLatch on
// the main thread for each line, suppressing the per-command generation bump, so
// the re-grades REPLACE-coalesce into ONE in-session step (P-E). Without this,
// each /api/command tool.pipe.attr is its OWN generation and APPENDS (discrete).
void pipeScrub(string[] lines) {
    string body_;
    foreach (l; lines) body_ ~= l ~ "\n";
    auto r = postJson("/api/script?interactive=true", body_);
    assert(r["status"].str == "ok",
        "interactive pipe scrub failed: " ~ r.toString);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}
long redoCount() {
    return getJson("/api/history")["redo"].array.length;
}

// TAGGED in-session entries on the undo stack (open-run gesture + re-grade steps
// before consolidation). Reads /api/history `inSession`.
long inSessionCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("inSession" in e.object) !is null && e["inSession"].boolean) ++n;
    return n;
}

// In-session RE-GRADE (Refire) entries on the undo stack. Reads /api/history
// `refire`. Used by the degenerate case to assert the n==1 tag-strip clears the
// refire bit too.
long refireCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("refire" in e.object) !is null && e["refire"].boolean) ++n;
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

// Select v6, VERIFY, do NOT drain the select entry (undoing a select restores a
// stale prior selection on the shared per-worker instance — the -j bleed). The
// select entry sits below the floor counters captured after it.
void selectV6() {
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);
    settle();
    auto s = getJson("/api/selection");
    assert(s["mode"].str == "vertices"
        && s["selectedVertices"].array.length == 1
        && s["selectedVertices"].array[0].integer == 6,
        "v6 selection did not take: " ~ s.toString);
}

// Pristine cube + EMPTY undo stack. Drop any stale tool, drain a lingering
// replay, then: reset (cube) → history.clear.
//
// Why NOT drainHistory() after /api/reset: SceneReset is itself undoable and
// its revert() restores the PRE-reset mesh (snapshotted at apply). At -j1 the
// preceding test leaves a dirty mesh, so an undo-of-reset rolls the cube BACK
// to that dirt. The old "drain before + drain after" dance left exactly one
// standing SceneReset entry whose snapshot was the prior test's geometry —
// undo=1 after baseline (vs undo=0 in isolation), and the test's own terminal
// drainHistory() popped it, reverting v6 to the stale prior mesh (the -j1
// cross-test-bleed flake: v6 came back (-1,0,1) / 0.503245, not the cube).
//
// history.clear is a SideEffect command (not undoable, not recorded): it wipes
// BOTH stacks WITHOUT touching the mesh, so the cube stays pristine AND undo=0.
// Nothing below the test's floor can revert the mesh into a stale state.
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
        auto c = v[6].array;   // startup cube v6 = (0.5, 0.5, 0.5)
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
        postJson("/api/reset", "");           // cube (SceneReset on the stack)
        postJson("/api/command", "history.clear"); // wipe stacks, keep the cube
        if (cubePristine() && undoCount() == 0) return;
        Thread.sleep(20.msecs);
    }
    postJson("/api/reset", "");
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

// SDL Ctrl+Z keystroke → handleKeyDown → navHistory(true). 122='z', mod 64 =
// KMOD_LCTRL. The ONLY in-session undo path (resyncSession runs; /api/undo does
// NOT and diverges — plan §8).
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// SDL Ctrl+Shift+Z keystroke → handleKeyDown → navHistory(false) (in-session
// redo, the symmetric partner of ctrlZ). mod 65 = KMOD_LCTRL (64) | KMOD_LSHIFT
// (1). Goes through the SAME navHistory chokepoint (resyncSession runs), so an
// in-session redo re-applies BOTH geometry and the config-restore apply hook.
string ctrlShiftZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":65,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating,
                cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// X-ring (normal +X, YZ plane) grab pixel on the VISIBLE semicircle for the
// default camera (110deg is well inside the hittable half). Verbatim from
// test_rs_insession_cancel.d / test_relocate_boundary_rs.d.
void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

// +X single-axis scale handle grab pixel + screen-space +X direction. Verbatim
// from test_relocate_boundary_rs.d.
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// +X move-arrow grab pixel + screen-space +X direction (for the OBJ-2 composed
// preset's Move sub-gesture).
void arrowGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                 out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 6.0f, pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size,        pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// One ON-ring rotate gesture against the CURRENT pivot, verify-and-retry keyed
// on the UNDO COUNT (a missed grab records nothing → retry; a hit records
// exactly one in-session entry → stop). Returns v6's post-gesture position.
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

// One ON-handle +X scale gesture against the CURRENT pivot, verify-and-retry on
// the UNDO COUNT. `dir` = +1 grow, -1 shrink.
double[3] scaleGestureOnAxis(long wantCount, double dir = 1.0, double mag = 80.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        axisGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(dir * mag * ux);
        int yb = ya + cast(int)(dir * mag * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 12));
        settle();
        if (undoCount() == wantCount) break;
    }
    return vert(6);
}

// Configure a TIGHT radial falloff centered at v6 (the standard re-grade
// witness: v6 in, the far corner v0 out until the radius widens). Must run
// AFTER the tool activates (the pipe stage is set up on tool.set).
void configTightRadial() {
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);
}

// Read back the live falloff `size` X component via the `?` query path
// (tool.pipe.attr falloff size ? → {"value":[x,y,z]}). `size` is exposed by
// FalloffStage.params() only for the Radial / Cylinder types, so the queried
// falloff must be Radial when this is called. This is the witness for P-A's
// CONFIG restore: after an in-session Ctrl+Z of a size re-grade, the live size
// must revert to its PRE-tweak value (not stay at the tweaked value).
double queryFalloffSizeX() {
    auto r = postJson("/api/command", "tool.pipe.attr falloff size ?");
    assert(r["status"].str == "ok",
        "falloff size query failed: " ~ r.toString);
    auto v = r["value"].array;
    return v[0].floating;
}

// P-C config-restore witnesses, read from /api/toolpipe/eval (which publishes
// the live SnapPacket.enabled + SymmetryPacket.enabled). Snap has no geometry
// signal at idle, so its enabled flag is the ONLY observable for its
// config-restore; symmetry's enabled flag corroborates the mirror-geometry
// witness.
bool querySnapEnabled() {
    return getJson("/api/toolpipe/eval")["snap"]["enabled"].boolean;
}
bool querySymmetryEnabled() {
    return getJson("/api/toolpipe/eval")["symmetry"]["enabled"].boolean;
}

// ===========================================================================
// (R-F) ROTATE F-mirror — re-grade + record + in-session Ctrl+Z + drop.
//
// timeline: tool.set TransformRotate → tight radial → ring gesture (1 entry)
//   → WIDEN radial (re-grade: v0 pulled along; APPEND → inSession 2) → assert
//   geometry re-graded + counts → in-session Ctrl+Z (revert ONLY the re-grade,
//   v0 back to post-gesture) → drop → ONE entry (D) → post-drop Ctrl+Z → cube.
// ===========================================================================
unittest {
    establishCubeBaseline();
    // NO selection → whole-mesh moving set, gated by the radial weights.
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");
    assert(inSessionCount() == 1, "one rotate gesture tagged inSession");
    auto v0AfterG = vert(0);   // far corner: barely rotated by the tight radius

    // WIDEN the radius → the landed rotation re-grades against the new weights at
    // idle, baking ONE appended in-session re-grade entry (config itself records
    // nothing).
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "the rotate falloff re-grade APPENDS one tagged in-session entry "
        ~ "(gesture + re-grade); got " ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "the CONFIG command records nothing; only the re-grade added an entry "
        ~ "(floor+2); floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the rotate re-grade MUST mutate geometry at idle (contract A): v0 "
        ~ "post-gesture (" ~ v0AfterG[0].to!string ~ "," ~ v0AfterG[1].to!string
        ~ "," ~ v0AfterG[2].to!string ~ ") re-graded (" ~ v0Regraded[0].to!string
        ~ "," ~ v0Regraded[1].to!string ~ "," ~ v0Regraded[2].to!string ~ ")");

    // Contract C: one in-session Ctrl+Z reverts ONLY the re-grade.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the rotate re-grade to the post-gesture "
        ~ "geometry (C); v0 expected (" ~ v0AfterG[0].to!string ~ ","
        ~ v0AfterG[1].to!string ~ "," ~ v0AfterG[2].to!string ~ ") got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    // The pop reverted geometry → the wrapper's mutation guard treats it as a
    // run boundary on the next idle frame: the run consolidates, the lone
    // surviving gesture's tag is stripped (n==1). Same closed-run behaviour as
    // the Move case-D (W1: a re-grade's redo within an open run is untestable —
    // the pop closes the run).
    assert(undoCount() == floor + 1,
        "after the in-session Ctrl+Z the re-grade is popped and the run holds "
        ~ "the lone rotate gesture (floor+1); floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);

    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop leaves ONE entry (the surviving rotate gesture) (D); floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated rotate run to the cube");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (S-F) SCALE F-mirror — same shape as (R-F) on the Scale bank.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");
    configTightRadial();
    settle();
    long floor = undoCount();

    scaleGestureOnAxis(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "scale gesture records one in-session entry");
    assert(inSessionCount() == 1, "one scale gesture tagged inSession");
    auto v0AfterG = vert(0);

    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "the scale falloff re-grade APPENDS one tagged in-session entry; got "
        ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "the CONFIG command records nothing; only the re-grade added an entry "
        ~ "(floor+2); floor=" ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the scale re-grade MUST mutate geometry at idle (contract A)");

    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the scale re-grade to the post-gesture "
        ~ "geometry (C); got (" ~ vert(0)[0].to!string ~ ","
        ~ vert(0)[1].to!string ~ "," ~ vert(0)[2].to!string ~ ")");
    assert(undoCount() == floor + 1,
        "after the in-session Ctrl+Z the run holds the lone scale gesture "
        ~ "(floor+1); now=" ~ undoCount().to!string);

    cmd("tool.set TransformScale off");
    settle();
    assert(undoCount() == floor + 1,
        "drop leaves ONE entry (the surviving scale gesture) (D); now="
        ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated scale run to the cube");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (R-DISCRETE-APPEND) ROTATE: two DISCRETE tweaks each APPEND (P-E) + widening
// clean revert.
//
// P-E FLIP (was R-REPLACE: "consecutive tweaks REPLACE"). tweak1 and tweak2 are
// two SEPARATE /api/command tool.pipe.attr calls — two DISCRETE tweaks, each its
// own tweak generation — so per reference fact G2 EACH is its own in-session
// undo step: tweak2 now APPENDS (inSession 2 -> 3, run floor+2 -> floor+3)
// instead of REPLACING tweak1. REPLACE is reserved for a CONTINUOUS interaction
// (a held slider scrub) — see the (P-E CONTINUOUS) case for the shared-generation
// REPLACE path. The widening + clean-revert property is unchanged: the second
// tweak still widens the support and one post-drop Ctrl+Z reverts every touched
// vert (each re-grade's once-per-window anchor covers its support, OBJ-3).
//
// drag → tweak1 (APPEND, inSession 2) → DISCRETE tweak2 (APPEND, inSession 3)
// with a WIDENING support → drop (consolidate gesture + BOTH re-grades to ONE) →
// one post-drop Ctrl+Z reverts the WHOLE run including the widened-support vert.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one entry");

    cmd(`tool.pipe.attr falloff size "3,3,3"`);   // tweak1 — APPEND
    settle();
    assert(inSessionCount() == 2,
        "first tweak APPENDS (gesture + re-grade); got " ~ inSessionCount().to!string);

    cmd(`tool.pipe.attr falloff size "6,6,6"`);   // tweak2 — DISCRETE → APPEND, WIDER
    settle();
    assert(inSessionCount() == 3,
        "a DISCRETE second tweak APPENDS its own re-grade (P-E G2): gesture + "
        ~ "tweak1 + tweak2 = 3; got " ~ inSessionCount().to!string);
    assert(undoCount() == floor + 3,
        "two discrete tweaks = two re-grade entries (floor+3); now="
        ~ undoCount().to!string);
    // v0 (the widened-support far corner, cube start (-0.5,-0.5,-0.5)) HAS moved
    // under the wide radius.
    auto v0Wide = vert(0);
    assert(!vertNear(v0Wide, [-0.5, -0.5, -0.5]),   // cube far corner start
        "the widened re-grade pulled v0 along; got (" ~ v0Wide[0].to!string ~ ","
        ~ v0Wide[1].to!string ~ "," ~ v0Wide[2].to!string ~ ")");

    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates gesture + BOTH discrete re-grades to ONE (D); now="
        ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    // The once-per-window anchors cover the WIDENED support, so v0 reverts
    // cleanly to the cube even though the FIRST tweak's tighter support never
    // touched it (OBJ-3).
    assertVertex(0, -0.5, -0.5, -0.5,
        "post-drop Ctrl+Z reverts the WIDENED-support v0 cleanly to the cube "
        ~ "(OBJ-3 anchor covers the wide support)");
    assertVertex(6, 0.5, 0.5, 0.5,
        "post-drop Ctrl+Z reverts v6 to the cube");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (R-D4) ROTATE multi-gesture-run — g2 must SURVIVE a following tweak.
//
// The REPLACE-vs-APPEND key has two parts: (1) the tail must be a REFIRE (a plain
// GESTURE entry is never dropped — the C1 multi-gesture hazard), AND (2) P-E: the
// tail refire must share the new entry's tweak GENERATION (same continuous
// interaction). g1 → tweak1 (APPEND) → g2 (its mouse-up clears refireAnchor +
// re-stamps; the tail is the GESTURE entry) → tweak2 (its tail is g2, a GESTURE →
// APPENDS, preserving g2 — the C1 fix) → tweak3.
//
// P-E FLIP (was: tweak3 REPLACES → FOUR entries). tweak3 here is a SEPARATE
// /api/command tool.pipe.attr call from tweak2 — a DISCRETE tweak, its own
// generation. So even though tweak3's tail IS a refire (tweak2), the generations
// differ → tweak3 APPENDS → FIVE entries (was four). Each discrete tweak is its
// own in-session step (G2). g2 still survives the merge.
//
// This pins the anchor/stamp wiring at the R/S commit sites (xfrm_transform.d
// rotate commit): without the per-gesture refireAnchor clear + stamp, g2's tweak
// would anchor to the stale post-g1 geometry; without the "tail is a refire" key
// (C1), tweak2 would erase g2.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();

    rotateGestureOnRing(floor + 1);            // g1
    assert(undoCount() == floor + 1, "g1 records one entry");

    cmd(`tool.pipe.attr falloff size "4,4,4"`);   // tweak1 — APPEND
    settle();
    assert(inSessionCount() == 2,
        "tweak1 APPENDS (g1 + tweak1); got " ~ inSessionCount().to!string);

    // g2: a second ring gesture. Its mouse-up clears refireAnchor + re-stamps the
    // version, opening a FRESH re-fire window. The run now holds g1 + tweak1 + g2.
    rotateGestureOnRing(floor + 3);
    assert(undoCount() == floor + 3,
        "g2 self-commits a THIRD in-session entry (g1 + tweak1 + g2); now="
        ~ undoCount().to!string);
    assert(inSessionCount() == 3, "three tagged in-session entries before tweak2");

    // tweak2: its tail is g2 (a GESTURE, not a refire) → it APPENDS (does NOT
    // erase g2). This is the C1 fix — keying on the Refire bit, not run-state.
    cmd(`tool.pipe.attr falloff size "8,8,8"`);
    settle();
    assert(inSessionCount() == 4,
        "tweak2's tail is g2 (a GESTURE) so it APPENDS — g2 SURVIVES; got "
        ~ inSessionCount().to!string);
    assert(undoCount() == floor + 4,
        "FOUR in-session entries (g1, tweak1, g2, tweak2); now="
        ~ undoCount().to!string);

    // tweak3: its tail IS tweak2 (a refire), but tweak3 is a DISCRETE tweak (a
    // separate /api command) so its generation differs from tweak2's → P-E gate
    // fails → it APPENDS. Stack grows to FIVE (was four pre-P-E).
    cmd(`tool.pipe.attr falloff size "12,12,12"`);
    settle();
    assert(inSessionCount() == 5,
        "tweak3 is a DISCRETE tweak (its own generation) so it APPENDS even "
        ~ "though its tail is a refire (P-E G2) — stack grows to 5; got "
        ~ inSessionCount().to!string);

    cmd("tool.set TransformRotate off");
    settle();
    postJson("/api/undo", "");
    settle();
    // The consolidated run reverts every touched vert to the run-START state.
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the WHOLE multi-gesture rotate run to the "
        ~ "cube (g2's contribution was preserved through the merge)");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (R-ZERO) ROTATE zero-gesture inertness (edge 1). A falloff change with NO
// gesture landed records NOTHING — the run is not open and the accumulator is
// trivial.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();
    // No gesture. A falloff packet change at idle.
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(undoCount() == floor,
        "a falloff change with NO landed rotate gesture is inert (edge 1); floor="
        ~ floor.to!string ~ " now=" ~ undoCount().to!string);
    assert(inSessionCount() == 0, "no tagged in-session entry on a zero-gesture run");
    assertVertex(6, 0.5, 0.5, 0.5, "zero-gesture falloff change did not move v6");
    cmd("tool.set TransformRotate off");
    settle();
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (S-ZERO) SCALE zero-gesture inertness (edge 1).
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");
    configTightRadial();
    settle();
    long floor = undoCount();
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(undoCount() == floor,
        "a falloff change with NO landed scale gesture is inert (edge 1); now="
        ~ undoCount().to!string);
    assert(inSessionCount() == 0, "no tagged in-session entry on a zero-gesture run");
    assertVertex(6, 0.5, 0.5, 0.5, "zero-gesture falloff change did not move v6");
    cmd("tool.set TransformScale off");
    settle();
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (TYPE-SWITCH) Falloff TYPE switch mid-run re-grades (not just a param tweak).
//
// A radial→linear TYPE switch is a packet INEQUALITY (falloffPacketsEqual
// compares type), so the re-fire site fires: the move gesture re-grades against
// the new weighting and bakes ONE in-session entry. Driven on the Move bank for
// a clean linear-weight witness; the R/S sites share the same packet-equality
// gate.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "4,4,4"`);
    settle();
    long floor = undoCount();

    // Move gesture via the +X arrow.
    {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move gesture records one entry");
    auto v0AfterG = vert(0);

    // Switch the TYPE radial → linear, then set the linear start + end. Each is a
    // packet inequality → a re-grade fires. P-E: these are THREE SEPARATE /api
    // commands — three DISCRETE tweaks, each its own generation — so each APPENDS
    // its own in-session step (was: all three REPLACEd into ONE, inSession 2).
    // gesture + 3 re-grades = 4 tagged in-session entries (G2).
    cmd("tool.pipe.attr falloff type linear");
    cmd(`tool.pipe.attr falloff start "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff end "-0.5,-0.5,-0.5"`);
    settle();
    assert(inSessionCount() == 4,
        "a falloff TYPE switch + start + end are THREE DISCRETE tweaks → each "
        ~ "APPENDS its own re-grade step (P-E G2): gesture + 3 = 4; got "
        ~ inSessionCount().to!string);
    assert(!vertNear(vert(0), v0AfterG),
        "the TYPE-switch re-grade moved geometry (different weighting)");

    cmd("tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5, "post-drop Ctrl+Z reverts the type-switch run");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (FALLOFF-OFF) Turning falloff OFF mid-run re-grades to weight=1 everywhere.
//
// Implemented semantics (asserted TRUTHFULLY): `type none` makes the packet
// empty; the absolute re-apply then runs with NO falloff, so every moving-set
// vert gets the FULL transform (weight 1). On a NO-selection move (whole-mesh
// moving set) every vert that was partially-weighted under the radial falloff
// jumps to the full translate. This is a packet change (radial → none) so it
// re-grades + records ONE entry.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "1,1,1"`);   // tight: v0 barely moves
    settle();
    long floor = undoCount();

    {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move gesture records one entry");
    auto v6AfterG = vert(6);   // fully moved (at the radial center)
    auto v0AfterG = vert(0);   // barely moved (tight radius far corner)

    // Turn falloff OFF mid-run → weight=1 everywhere → v0 jumps to the full
    // translate (same delta v6 received).
    cmd("tool.pipe.attr falloff type none");
    settle();
    assert(inSessionCount() == 2,
        "turning falloff OFF is a packet change → re-grade APPENDS one entry; got "
        ~ inSessionCount().to!string);
    auto v0Off = vert(0);
    assert(!vertNear(v0Off, v0AfterG),
        "falloff-off re-grades v0 to the FULL transform (weight 1); v0 was ("
        ~ v0AfterG[0].to!string ~ "," ~ v0AfterG[1].to!string ~ ","
        ~ v0AfterG[2].to!string ~ ") now (" ~ v0Off[0].to!string ~ ","
        ~ v0Off[1].to!string ~ "," ~ v0Off[2].to!string ~ ")");
    // The full-weight delta v0 received equals the delta v6 received (both got
    // the unweighted translate). v6 is unchanged by the off-switch (it was
    // already weight≈1 at the center).
    auto v6Off = vert(6);
    // Compare the OFF-state translate of v0 against v6's translate from the cube:
    // both equal the gesture's world delta. v6 delta:
    double[3] v6Delta = [v6Off[0]-0.5,    v6Off[1]-0.5,    v6Off[2]-0.5];
    double[3] v0Delta = [v0Off[0]-(-0.5), v0Off[1]-(-0.5), v0Off[2]-(-0.5)];
    assert(fabs(v6Delta[0]-v0Delta[0]) < 1e-2 && fabs(v6Delta[1]-v0Delta[1]) < 1e-2
        && fabs(v6Delta[2]-v0Delta[2]) < 1e-2,
        "falloff-off gives EVERY moving vert the same full translate: v6 delta ("
        ~ v6Delta[0].to!string ~ "," ~ v6Delta[1].to!string ~ "," ~ v6Delta[2].to!string
        ~ ") vs v0 delta (" ~ v0Delta[0].to!string ~ "," ~ v0Delta[1].to!string
        ~ "," ~ v0Delta[2].to!string ~ ")");

    cmd("tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5, "post-drop Ctrl+Z reverts the falloff-off run");
    drainHistory();
}

// ===========================================================================
// (SEL-BOUNDARY) Falloff change AFTER a selection boundary is inert (edge 4).
//
// A selection change mid-run trips the wrapper's selection/mutation guard FIRST
// (it runs before the falloff site in update()): the open run consolidates +
// nextRun() → the run is CLOSED. A subsequent falloff change then sees
// runOpen() false → inert. Correct: a committed prior run must NOT re-grade.
// ===========================================================================
unittest {
    establishCubeBaseline();
    selectV6();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "4,4,4"`);
    settle();
    long floor = undoCount();

    {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move gesture records one entry");

    // CHANGE the selection → the wrapper's guard consolidates + closes the run.
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    settle();
    long afterSel = undoCount();

    // A falloff change NOW (run closed) re-grades NOTHING — no new in-session
    // entry, no geometry change to v6's committed run.
    auto v6Committed = vert(6);
    cmd(`tool.pipe.attr falloff size "8,8,8"`);
    settle();
    assert(undoCount() == afterSel,
        "a falloff change after a selection boundary is inert (edge 4): the run "
        ~ "is closed (runOpen() false); afterSel=" ~ afterSel.to!string ~ " now="
        ~ undoCount().to!string);
    assert(inSessionCount() == 0,
        "no open run after the selection boundary → no tagged in-session entry");
    assert(vertNear(vert(6), v6Committed),
        "the closed run's v6 geometry is untouched by the post-boundary falloff "
        ~ "change");

    cmd("tool.set move off");
    settle();
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (SYMMETRY) A symmetric re-grade drives the mirror partner along the OPPOSITE
// X axis — and KEEPS doing so after the re-grade.
//
// The discriminating move is +X, NOT +Y. A +Y translate mirrors to the SAME +Y
// on both half-spaces, so a "find any X-mirror pair" scan trivially passes even
// with the symmetry stage broken (the cube ALWAYS has mirror pairs, and a +Y
// move leaves x = -x intact for free). To actually witness the mirror pass we
// drive v6 (the +X corner) along +X with v6 alone selected and the falloff
// centered on it: v6 is the lone-selected driver, so the symmetry stage writes
// its mirror partner v7 (the -X corner, same y,z) to the MIRRORED position —
// v7 moves -X by the same magnitude v6 moved +X. We assert that SPECIFIC vid
// pair with a NON-TRIVIAL X displacement (x6 != 0.5, so the move landed; x7 =
// -x6, so symmetry drove it; y/z equal). If the symmetry stage is disabled v7
// never moves, x7 stays -0.5 != -x6, and this assert FAILS.
//
// We grade the pair BEFORE the falloff tweak (proves the live drag mirrored)
// and AFTER it (proves the absolute re-apply REUSED the captured symmetry pass
// — line 2749's applySymmetryMirror over `toProcess`).
// ===========================================================================
unittest {
    establishCubeBaseline();
    // NO selection → whole-mesh moving set (so widening the radius actually
    // re-grades the partially-weighted off-center verts). The symmetry base-side
    // rule still drives v7 from v6's mirror, so the specific v6/v7 pair stays
    // x6 = -x7 throughout.
    cmd("tool.set move");
    cmd("tool.pipe.attr symmetry enabled 1");
    cmd("tool.pipe.attr symmetry axis x");          // X plane (x=0)
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    // Centre the radial falloff ON the symmetry plane (x=0), aligned with the
    // v6/v7 row. v6 and its X-mirror v7 are then EQUIDISTANT from the centre →
    // equal weight, so the `x6 = -x7` mirror relation holds. (Centring on v6
    // itself — the pre-Stage-2 setup — made the falloff ASYMMETRIC about the
    // plane: under the two-pass symmetry mirror v7 is now weighted at its OWN
    // mirrored position, which for a v6-centred sphere of radius 1 is 0, so v7
    // would correctly NOT move — the deliberate distance-falloff divergence of
    // doc/symmetry_deform_plan.md #8, covered by tests/test_symm_falloff.d (b).
    // This test exercises the refire/undo mechanics, so it uses a SYMMETRIC
    // falloff where mirror == position-copy and the pair relation is stable.)
    cmd(`tool.pipe.attr falloff center "0,0.5,0.5"`); // on x=0 plane, v6/v7 row
    cmd(`tool.pipe.attr falloff size "1,1,1"`);     // v6/v7 partially weighted, far verts out
    settle();
    long floor = undoCount();

    // Drive along +X via the +X arrow. v6 (the +X corner, at the falloff center →
    // full weight) moves +X; the symmetry stage mirrors it onto v7 (= pairOf[6],
    // the -X corner) which therefore moves -X. A +X move is the discriminator:
    // v6 → +X, v7 → -X (OPPOSITE), unlike a +Y move which would push BOTH the
    // same way (the trivial pass the prior version accidentally accepted).
    {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "symmetric move gesture records one entry");

    // Grade the SPECIFIC v6/v7 pair after the live drag. v6 moved +X off 0.5
    // (non-trivial), v7's x is its negative (the mirror drove it), y/z equal.
    auto v6g = vert(6);
    auto v7g = vert(7);
    assert(fabs(v6g[0] - 0.5) > 0.05,
        "the +X drag moved v6 off its start x=0.5 (non-trivial X displacement); "
        ~ "v6.x=" ~ v6g[0].to!string);
    assert(fabs(v6g[0] + v7g[0]) < 1e-2
        && fabs(v6g[1] - v7g[1]) < 1e-2
        && fabs(v6g[2] - v7g[2]) < 1e-2,
        "X-symmetry drove the mirror partner v7 to -v6.x along the OPPOSITE axis "
        ~ "(x6 = -x7, y/z equal) DURING the drag; v6=(" ~ v6g[0].to!string ~ ","
        ~ v6g[1].to!string ~ "," ~ v6g[2].to!string ~ ") v7=(" ~ v7g[0].to!string
        ~ "," ~ v7g[1].to!string ~ "," ~ v7g[2].to!string ~ ")");

    // Re-grade: widen the radius. The absolute re-apply REUSES the captured
    // symmetry pass, so the v6/v7 mirror relation must STILL hold afterward.
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2, "symmetric re-grade appends one entry; got "
        ~ inSessionCount().to!string);

    auto v6r = vert(6);
    auto v7r = vert(7);
    assert(fabs(v6r[0] - 0.5) > 0.05,
        "post-re-grade v6 still carries a non-trivial X displacement; v6.x="
        ~ v6r[0].to!string);
    assert(fabs(v6r[0] + v7r[0]) < 1e-2
        && fabs(v6r[1] - v7r[1]) < 1e-2
        && fabs(v6r[2] - v7r[2]) < 1e-2,
        "after the falloff re-grade the v6/v7 X-mirror relation STILL holds "
        ~ "(x6 = -x7, y/z equal) — the absolute re-apply reused the captured "
        ~ "symmetry pass; v6=(" ~ v6r[0].to!string ~ "," ~ v6r[1].to!string ~ ","
        ~ v6r[2].to!string ~ ") v7=(" ~ v7r[0].to!string ~ "," ~ v7r[1].to!string
        ~ "," ~ v7r[2].to!string ~ ")");

    cmd("tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5, "post-drop Ctrl+Z reverts the symmetric run");
    assertVertex(7, -0.5, 0.5, 0.5,
        "post-drop Ctrl+Z reverts the symmetry-driven mirror partner v7 too");
    cmd("tool.pipe.attr symmetry enabled 0");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (R-DEGEN) Degenerate pop → tweak → drop = ONE consolidated entry (edge 7).
//
// TWO rotate gestures → in-session Ctrl+Z (pop g2) → falloff tweak (INERT: the
// pop bumped mutationVersion away from the stamp, so the staleness gate makes
// the site inert — a popped gesture is NOT resurrected, no re-grade records) →
// drop → ONE consolidated entry (the surviving g1; n==1 strips BOTH the
// inSession AND the refire bits, asserted via /api/history's refire field).
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();

    rotateGestureOnRing(floor + 1);            // g1
    rotateGestureOnRing(floor + 2);            // g2
    assert(undoCount() == floor + 2,
        "two rotate gestures record two in-session entries; now="
        ~ undoCount().to!string);
    auto v6AfterG1 = vert(6);   // captured after the pop below proves the revert

    // In-session Ctrl+Z pops g2. The pop bumps mutationVersion (geometry
    // reverted) and resyncSession re-baselines, so the wrapper's mutation guard
    // closes the run on the next idle frame → the lone g1 consolidates as ONE
    // untagged surviving entry.
    playAndWait(ctrlZ(50.0));
    settle();
    v6AfterG1 = vert(6);
    assert(undoCount() == floor + 1,
        "in-session Ctrl+Z pops g2, the run closes around g1 (floor+1); now="
        ~ undoCount().to!string);

    // Falloff tweak — INERT (staleness gate: version no longer matches the stamp,
    // AND the run is closed). No re-grade records; geometry stays at g1.
    long beforeTweak = undoCount();
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(undoCount() == beforeTweak,
        "a falloff tweak after a popped gesture is INERT (staleness gate + closed "
        ~ "run); beforeTweak=" ~ beforeTweak.to!string ~ " now="
        ~ undoCount().to!string);
    assert(vertNear(vert(6), v6AfterG1),
        "the inert tweak did not resurrect g2 nor move g1's geometry");

    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop leaves ONE consolidated entry (the surviving g1) (D); now="
        ~ undoCount().to!string);
    // n==1 consolidate strips BOTH the inSession AND the refire bits.
    assert(inSessionCount() == 0,
        "the surviving consolidated entry is NOT tagged inSession (n==1 strip)");
    assert(refireCount() == 0,
        "the surviving consolidated entry is NOT tagged refire (n==1 strips both "
        ~ "bits); got " ~ refireCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the lone surviving rotate gesture to cube");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (OBJ-2) Composed Move-then-Rotate is TWO runs; a post-Rotate tweak re-grades
// only the Rotate run.
//
// A composed T+R+S preset (Transform) lets one "session" hold both a Move arrow
// and a Rotate ring. A bank switch is a RUN BOUNDARY (noteRunBank consolidates +
// nextRun), so Move-then-Rotate is TWO runs. A falloff tweak after the Rotate
// gesture re-grades ONLY the Rotate run (currentRunBank == Rotate single-winner
// gate); the consolidated Move entry is untouched.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set Transform");      // composed T+R+S
    cmd("tool.pipe.attr falloff type radial");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff size "4,4,4"`);
    settle();
    long floor = undoCount();

    // Move sub-gesture via the +X arrow.
    {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move sub-gesture records one entry (run 1)");
    auto v6AfterMove = vert(6);

    // Rotate sub-gesture via the X-ring. The bank switch (Move → Rotate) is a run
    // boundary: noteRunBank consolidates run 1 + opens run 2.
    rotateGestureOnRing(floor + 2);
    assert(undoCount() == floor + 2,
        "rotate sub-gesture is a SECOND run (bank switch boundary); now="
        ~ undoCount().to!string);
    auto v6AfterRot = vert(6);
    assert(!vertNear(v6AfterRot, v6AfterMove),
        "the rotate sub-gesture displaced v6 from its post-move position");

    // Capture the Move run's committed contribution before the tweak: pick a vert
    // OUTSIDE the rotate witness. We assert the tweak re-grades the Rotate run by
    // counts + by the Rotate run being the open one.
    cmd(`tool.pipe.attr falloff size "8,8,8"`);
    settle();
    // The tweak re-grades the OPEN (Rotate) run → it APPENDS one tagged
    // in-session entry to run 2 (the Move run is run 1, already consolidated /
    // not the open run, so it gets NO re-grade — single-winner gate).
    assert(inSessionCount() == 2,
        "the post-Rotate falloff tweak re-grades the OPEN Rotate run (the Rotate "
        ~ "gesture + its re-grade are the two tagged in-session entries; the Move "
        ~ "run was consolidated at the bank-switch boundary and is untagged); "
        ~ "inSession=" ~ inSessionCount().to!string);
    assert(undoCount() == floor + 3,
        "the tweak adds ONE re-grade entry to the Rotate run (the Move run is "
        ~ "untouched — single-winner); expected floor+3, now=" ~ undoCount().to!string);

    cmd("tool.set Transform off");
    settle();
    // Drop consolidates the open Rotate run; the Move run was already a separate
    // surviving entry. So TWO surviving entries: the Move run + the consolidated
    // Rotate run. Two post-drop Ctrl+Z revert both back to the cube.
    postJson("/api/undo", "");   // pop the consolidated Rotate run
    settle();
    assert(vertNear(vert(6), v6AfterMove),
        "popping the Rotate run reverts v6 to its post-MOVE position (the Move "
        ~ "run is a SEPARATE surviving entry, untouched by the Rotate re-grade)");
    postJson("/api/undo", "");   // pop the Move run
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "popping the Move run reverts v6 to the cube — TWO distinct runs");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (CONFIG-RESTORE MOVE) P-A: in-session Ctrl+Z of a falloff re-grade reverts
// the falloff CONFIG together with the geometry; redo re-applies both.
//
// timeline: tool.set move → tight radial (size 1) → +X arrow gesture (1 entry)
//   → WIDEN radial size 1→5 (re-grade APPENDS; v0 pulled along) → assert
//   size==5 AND geometry re-graded → in-session Ctrl+Z → assert v0 back to
//   post-gesture AND size reverted to 1 (P-A: config follows the undo) →
//   in-session Ctrl+Shift+Z (redo) → assert v0 re-graded AND size back to 5.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();          // radial, size 1,1,1, centered at v6
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    // +X move-arrow gesture, verify-and-retry on the undo count.
    {
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            settle();
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move gesture records one in-session entry");
    auto v0AfterG = vert(0);

    // WIDEN the radius 1→5: the landed translate re-grades against the new
    // weights, baking ONE appended in-session entry. The config command itself
    // records nothing.
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "the move falloff re-grade APPENDS one tagged in-session entry; got "
        ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "config records nothing; only the re-grade added an entry (floor+2)");
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the move re-grade MUST mutate geometry at idle (contract A)");

    // In-session Ctrl+Z: P-A — reverts BOTH the geometry (back to post-gesture)
    // AND the falloff config (size back to 1).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the move re-grade geometry to post-gesture; "
        ~ "got (" ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(queryFalloffSizeX() == 1.0,
        "P-A: in-session Ctrl+Z restores the falloff config WITH the geometry "
        ~ "(size reverted 5→1); got " ~ queryFalloffSizeX().to!string);

    // In-session Ctrl+Shift+Z (redo): re-applies BOTH — geometry re-graded AND
    // config back to 5. The pop above did NOT consolidate the run because no
    // boundary fired (a plain in-session undo keeps the run open for redo).
    playAndWait(ctrlShiftZ(70.0));
    settle();
    assert(vertNear(vert(0), v0Regraded),
        "in-session redo re-applies the move re-grade geometry; got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(queryFalloffSizeX() == 5.0,
        "P-A: in-session redo re-applies the falloff config (size 1→5); got "
        ~ queryFalloffSizeX().to!string);

    cmd("tool.set move off");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (CONFIG-RESTORE ROTATE) P-A on the Rotate bank — same shape as the Move case.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");
    auto v0AfterG = vert(0);

    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2, "the rotate falloff re-grade APPENDS one entry");
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the rotate re-grade MUST mutate geometry at idle (contract A)");

    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the rotate re-grade geometry to post-gesture");
    assert(queryFalloffSizeX() == 1.0,
        "P-A: in-session Ctrl+Z restores the falloff config (size 5→1) on the "
        ~ "Rotate bank; got " ~ queryFalloffSizeX().to!string);

    playAndWait(ctrlShiftZ(70.0));
    settle();
    assert(vertNear(vert(0), v0Regraded),
        "in-session redo re-applies the rotate re-grade geometry");
    assert(queryFalloffSizeX() == 5.0,
        "P-A: in-session redo re-applies the falloff config (size 1→5) on the "
        ~ "Rotate bank; got " ~ queryFalloffSizeX().to!string);

    cmd("tool.set TransformRotate off");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (CONFIG-RESTORE SCALE) P-A on the Scale bank — same shape.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");
    configTightRadial();
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    scaleGestureOnAxis(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "scale gesture records one in-session entry");
    auto v0AfterG = vert(0);

    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2, "the scale falloff re-grade APPENDS one entry");
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the scale re-grade MUST mutate geometry at idle (contract A)");

    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the scale re-grade geometry to post-gesture");
    assert(queryFalloffSizeX() == 1.0,
        "P-A: in-session Ctrl+Z restores the falloff config (size 5→1) on the "
        ~ "Scale bank; got " ~ queryFalloffSizeX().to!string);

    playAndWait(ctrlShiftZ(70.0));
    settle();
    assert(vertNear(vert(0), v0Regraded),
        "in-session redo re-applies the scale re-grade geometry");
    assert(queryFalloffSizeX() == 5.0,
        "P-A: in-session redo re-applies the falloff config (size 1→5) on the "
        ~ "Scale bank; got " ~ queryFalloffSizeX().to!string);

    cmd("tool.set TransformScale off");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (POST-DROP CONFIG-RESTORE MOVE) P-A BLOCKER fix — the consolidated-run case.
//
// The in-session (CONFIG-RESTORE *) cases above pop the re-grade entry BEFORE
// the drop, so the refire entry's OWN config hook fires. This case is the
// blocker the reviewer flagged: NO in-session Ctrl+Z, so BOTH the gesture and
// the falloff-refire entries are alive at DROP. `tool.set move off` consolidates
// them via MeshVertexEdit.mergeRun, which keeps first.revert + last.apply. The
// merged.revert is therefore the GESTURE entry's revert — which must now restore
// BOTH the pin AND the RUN-START falloff config (size 1). Before the uniform-hook
// fix the gesture revert restored geometry+pin only, leaving the falloff handle
// stranded at the post-tweak value (size 5) after a single post-drop Ctrl+Z.
//
// timeline: tool.set move → tight radial (size 1) → +X arrow gesture (1 entry)
//   → WIDEN radial 1→5 (re-grade APPENDS → 2 entries) → DROP (consolidate to 1
//   via mergeRun) → ONE post-drop Ctrl+Z → assert geometry reverts to the cube
//   AND size reverts to the RUN-START value (1), NOT the post-tweak 5.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();          // radial, size 1,1,1, centered at v6
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    // +X move-arrow gesture, verify-and-retry on the undo count.
    {
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        foreach (attempt; 0 .. 6) {
            settle();
            arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
            playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      xa, ya, xa + cast(int)(60.0 * ux),
                                      ya + cast(int)(60.0 * uy), 10));
            settle();
            if (undoCount() == floor + 1) break;
        }
    }
    assert(undoCount() == floor + 1, "move gesture records one in-session entry");

    // WIDEN 1→5 → ONE appended re-grade entry. Both entries now alive at drop.
    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2,
        "the move falloff re-grade APPENDS one tagged in-session entry; got "
        ~ inSessionCount().to!string);
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");

    // DROP — consolidate [gesture, refire] to ONE entry via mergeRun. NO
    // in-session Ctrl+Z first, so the refire entry survives into the merge.
    cmd("tool.set move off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates the run to ONE entry (D); floor=" ~ floor.to!string
        ~ " now=" ~ undoCount().to!string);

    // ONE post-drop Ctrl+Z: P-A BLOCKER — the merged first.revert (gesture)
    // restores BOTH the geometry (back to the cube) AND the run-start config.
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated move run to the cube");
    assert(queryFalloffSizeX() == 1.0,
        "P-A BLOCKER: post-drop Ctrl+Z restores the RUN-START falloff config "
        ~ "(size reverted 5→1) on the merged run, NOT stranded at the post-tweak "
        ~ "5; got " ~ queryFalloffSizeX().to!string);

    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (POST-DROP CONFIG-RESTORE ROTATE) P-A BLOCKER on the Rotate bank — same shape.
// The merged first.revert here is the ROTATE gesture's accumulator+config hook
// (rotate.d commitEdit), which must restore the run-start falloff config.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformRotate");
    configTightRadial();
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    rotateGestureOnRing(floor + 1);
    assert(undoCount() == floor + 1, "rotate gesture records one in-session entry");

    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2, "the rotate falloff re-grade APPENDS one entry");
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");

    cmd("tool.set TransformRotate off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates the rotate run to ONE entry (D); now="
        ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated rotate run to the cube");
    assert(queryFalloffSizeX() == 1.0,
        "P-A BLOCKER: post-drop Ctrl+Z restores the RUN-START falloff config "
        ~ "(size 5→1) on the merged Rotate run; got "
        ~ queryFalloffSizeX().to!string);

    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (POST-DROP CONFIG-RESTORE SCALE) P-A BLOCKER on the Scale bank — same shape.
// The merged first.revert is the SCALE gesture's accumulator+config hook
// (scale.d commitEdit).
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set TransformScale");
    configTightRadial();
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: falloff size starts at 1");

    scaleGestureOnAxis(floor + 1, +1.0);
    assert(undoCount() == floor + 1, "scale gesture records one in-session entry");

    cmd(`tool.pipe.attr falloff size "5,5,5"`);
    settle();
    assert(inSessionCount() == 2, "the scale falloff re-grade APPENDS one entry");
    assert(queryFalloffSizeX() == 5.0, "the tweak set the live falloff size to 5");

    cmd("tool.set TransformScale off");
    settle();
    assert(undoCount() == floor + 1,
        "drop consolidates the scale run to ONE entry (D); now="
        ~ undoCount().to!string);

    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "one post-drop Ctrl+Z reverts the consolidated scale run to the cube");
    assert(queryFalloffSizeX() == 1.0,
        "P-A BLOCKER: post-drop Ctrl+Z restores the RUN-START falloff config "
        ~ "(size 5→1) on the merged Scale run; got "
        ~ queryFalloffSizeX().to!string);

    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// One +X move-arrow gesture against the CURRENT pivot, verify-and-retry keyed
// on the UNDO COUNT (mirrors the inline pattern in CONFIG-RESTORE MOVE). Returns
// after the gesture records exactly one in-session entry (undoCount == want).
void moveArrowGesture(long want) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        arrowGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xa + cast(int)(60.0 * ux),
                                  ya + cast(int)(60.0 * uy), 10));
        settle();
        if (undoCount() == want) return;
    }
}

// ===========================================================================
// (P-C SYMMETRY MID-RUN, toggle-on) A symmetry toggle AFTER a committed move
// gesture participates in the generalized refire trigger + the uniform
// config-restore hook family: the re-grade re-runs the composed fold WITH the
// live symmetry pass and records ONE tagged in-session entry; an in-session /
// post-drop undo restores the symmetry CONFIG together with the geometry.
//
// NOTE on the geometry witness: symmetry pairs vertices by their CURRENT
// position (SymmetryStage.rebuildPairing on the live mesh). When symmetry is
// enabled AFTER a gesture has already displaced a vertex off the plane, that
// vertex no longer pairs with its old mirror, so toggling symmetry on mid-run
// re-grades to byte-identical geometry on this fixture (no valid pair → no
// mirror write). That is faithful positional-symmetry behaviour, NOT a P-C bug
// (the geometric re-grade with symmetry is exercised by the (SYMMETRY) case
// above, which captures the pristine-mesh pairing at mouse-down). The P-C
// deliverable witnessed here is the TRIGGER + CONFIG-RESTORE, exactly like the
// (P-C SNAP MID-RUN) case. The symmetry-on companion that DOES drive the mirror
// (pairing captured at mouse-down) is the pre-existing (SYMMETRY) test.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();                         // stable falloff baseline
    cmd("tool.pipe.attr symmetry enabled 0");    // OFF at mouse-down
    settle();
    long floor = undoCount();
    assert(!querySymmetryEnabled(), "pre-condition: symmetry starts OFF");

    moveArrowGesture(floor + 1);
    assert(undoCount() == floor + 1, "move gesture records one in-session entry");
    auto v0AfterG = vert(0);

    // Toggle symmetry ON mid-run (X plane). P-C: the trigger fires (symmetry
    // packet changed) → ONE tagged in-session entry is recorded, carrying the
    // symmetry config-restore hooks.
    cmd("tool.pipe.attr symmetry enabled 1");
    cmd("tool.pipe.attr symmetry axis x");
    settle();
    assert(querySymmetryEnabled(), "symmetry is now enabled");
    assert(inSessionCount() == 2,
        "the symmetry toggle re-grade APPENDS one tagged in-session entry; got "
        ~ inSessionCount().to!string);

    // In-session Ctrl+Z: restores the symmetry config (enabled→false). Geometry
    // stays at the post-gesture position (positional pairing found no mirror on
    // the deformed mesh — see the NOTE above).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(!querySymmetryEnabled(),
        "P-C: in-session Ctrl+Z restores the symmetry config (enabled 1→0)");
    assert(vertNear(vert(0), v0AfterG),
        "the symmetry-toggle re-grade left geometry at the post-gesture position");

    // Post-drop: drop the tool (consolidates), one Ctrl+Z reverts the whole run
    // to the cube AND restores the run-start symmetry config (off).
    cmd("tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5, "post-drop undo reverts the move run to the cube");
    assert(!querySymmetryEnabled(),
        "P-C uniform-hook: post-drop undo restores the RUN-START symmetry config "
        ~ "(off) on the merged run");

    cmd("tool.pipe.attr symmetry enabled 0");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (P-C SNAP MID-RUN) A snap toggle AFTER a committed move gesture participates
// in the generalized refire trigger + the uniform config-restore hook family.
// Snap is a CURSOR-time op (snapCursor during the live drag), NOT part of the
// composed absolute fold — so a snap-only toggle at idle re-grades to
// byte-identical geometry. Its P-C role is config-restore: an in-session /
// post-drop undo restores the snap config (enabled) together with the geometry.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();                         // gives a stable falloff baseline
    cmd("tool.pipe.attr snap enabled false");    // OFF at mouse-down
    settle();
    long floor = undoCount();
    assert(!querySnapEnabled(), "pre-condition: snap starts OFF");

    moveArrowGesture(floor + 1);
    assert(undoCount() == floor + 1, "move gesture records one in-session entry");
    auto v0AfterG = vert(0);

    // Toggle snap ON mid-run. The trigger fires (snap packet changed) → a
    // re-grade entry is recorded carrying the snap config-restore hooks. Geometry
    // is byte-identical (snap not in the fold); the witness here is the CONFIG.
    cmd("tool.pipe.attr snap enabled true");
    settle();
    assert(querySnapEnabled(), "snap is now enabled");
    assert(inSessionCount() >= 2,
        "the snap toggle re-grade APPENDS a tagged in-session entry; got "
        ~ inSessionCount().to!string);

    // In-session Ctrl+Z: restores the snap config (enabled→false). Geometry stays
    // at the post-gesture position (the snap-only re-grade moved nothing).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(!querySnapEnabled(),
        "P-C: in-session Ctrl+Z restores the snap config (enabled 1→0)");
    assert(vertNear(vert(0), v0AfterG),
        "the snap-only re-grade left geometry unchanged (snap not in the fold)");

    // Post-drop: drop + one undo restores the cube AND the run-start snap config.
    cmd("tool.set move off");
    settle();
    postJson("/api/undo", "");
    settle();
    assertVertex(6, 0.5, 0.5, 0.5, "post-drop undo reverts the move run to the cube");
    assert(!querySnapEnabled(),
        "P-C uniform-hook: post-drop undo restores the RUN-START snap config "
        ~ "(off) on the merged run");

    cmd("tool.pipe.attr snap enabled false");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (P-C ACEN-MODE BOUNDARY) An action-center MODE change mid-run is a session
// BOUNDARY (NOT a refire): it consolidates the open run + opens a new one, so
// the next gesture is a separate surviving undo entry. The actr.* command
// itself is SideEffect — it records NOTHING — the boundary is detected by the
// wrapper's idle ACEN-mode poll.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    // Latch an explicit ACEN mode so the first idle poll records it without
    // firing a boundary, and the later change to a DIFFERENT mode is a clean
    // mode delta.
    cmd("actr.select");
    settle();
    long floor = undoCount();

    moveArrowGesture(floor + 1);
    assert(undoCount() == floor + 1, "drag1 records one in-session entry (run A)");

    // ACEN MODE CHANGE mid-run → BOUNDARY. actr.origin is SideEffect (records
    // nothing); the wrapper's idle poll consolidates run A.
    cmd("actr.origin");
    settle();
    assert(undoCount() == floor + 1,
        "the actr.* mode change itself records NOTHING (still floor+1); got "
        ~ undoCount().to!string);
    // The open run consolidated: no tagged in-session entry lingers as a
    // re-gradable tail (the boundary closed the run + bumped the run id).
    assert(inSessionCount() <= 1,
        "after the ACEN-mode boundary the prior run is consolidated; got "
        ~ inSessionCount().to!string ~ " in-session entries");

    // drag2 opens a NEW run (run B) → a SEPARATE surviving entry. If the boundary
    // had NOT fired, drag2 would coalesce into run A and the drop would leave
    // ONE entry, not two.
    moveArrowGesture(floor + 2);
    assert(undoCount() == floor + 2,
        "drag2 opens a NEW run after the boundary (floor+2); got "
        ~ undoCount().to!string);

    cmd("tool.set move off");
    settle();
    // Two surviving runs ⇒ two post-drop undo steps to unwind both.
    assert(undoCount() == floor + 2,
        "the drop leaves the two consolidated runs (boundary kept them separate);"
        ~ " got " ~ undoCount().to!string);
    postJson("/api/undo", "");
    settle();
    postJson("/api/undo", "");
    settle();
    assert(undoCount() == floor,
        "two post-drop undos unwind BOTH runs back to the select floor; got "
        ~ undoCount().to!string);
    assertVertex(6, 0.5, 0.5, 0.5,
        "after unwinding both runs the cube is restored");

    cmd("actr.auto");
    drainHistory();
}

// Tagged-in-session refire entries' tweakGen tokens, oldest→newest. Reads
// /api/history's per-entry `tweakGen`. Used to assert two DISCRETE tweaks carry
// DIFFERENT generations (the P-E discriminator) while the gesture + tweaks form
// distinct undo steps.
long[] refireTweakGens() {
    long[] gens;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("refire" in e.object) !is null && e["refire"].boolean
         && ("tweakGen" in e.object) !is null)
            gens ~= e["tweakGen"].integer;
    return gens;
}

// ===========================================================================
// (P-E DISCRETE GRANULARITY) The P-E deliverable: each DISCRETE pipe tweak is
// its OWN in-session undo step (reference fact G2: drag + 2 discrete tweaks = 3
// undo steps; a continuous scrub = 1).
//
// timeline: tool.set move → tight radial (size 1) → +X arrow gesture (1 step)
//   → DISCRETE tweak1 size 1→3 (APPEND → 2 steps, v0 re-grades) → DISCRETE
//   tweak2 size 3→6 (APPEND → 3 steps, v0 re-grades further). The G2 STEP-COUNT
//   witness is the THREE distinct in-session entries (gesture + tweak1 + tweak2
//   = floor+3): had the two discrete tweaks wrongly REPLACEd into one step there
//   would be only TWO (floor+2). The two refire entries also carry DIFFERENT
//   tweakGen tokens — the concrete discriminator that forced tweak2 to APPEND —
//   and v0 differs after each tweak (each did distinct re-grade work).
//
// NOTE on per-step GEOMETRY: every re-grade of one re-fire WINDOW anchors its
// before[] to the SAME post-gesture snapshot (the once-per-window anchor, OBJ-3,
// so a widening scrub reverts cleanly), so an in-session Ctrl+Z of the LAST
// re-grade reverts geometry straight to POST-GESTURE regardless of how many
// discrete tweaks preceded it. The distinct STEP COUNT (not a per-step geometry
// ladder) is therefore the faithful G2 witness; we assert ONE Ctrl+Z lands at
// post-gesture (the anchor) and that the run then consolidates (a
// geometry-reverting pop bumps mutationVersion → the wrapper's idle mutation
// guard closes the run, the (R-F)-documented behaviour).
//
// (The CONTINUOUS-scrub REPLACE counterpart — a held slider whose per-frame
// setAttr stream shares ONE generation and collapses to ONE step — is NOT
// headlessly drivable through /api/command, since every /api command is its own
// discrete generation by design. It is verified at the gate level by the
// generation-match REPLACE assertion in test_history_insession.d and needs a
// manual / forms-slider check in the live editor.)
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();          // radial, size 1,1,1, centered at v6
    settle();
    long floor = undoCount();

    moveArrowGesture(floor + 1);
    assert(undoCount() == floor + 1, "move gesture records one in-session step");
    auto v0AfterG = vert(0);      // far corner, barely moved under the tight radius

    // DISCRETE tweak1: widen 1→3. APPEND → 2 in-session steps; v0 re-grades.
    cmd(`tool.pipe.attr falloff size "3,3,3"`);
    settle();
    assert(inSessionCount() == 2,
        "tweak1 APPENDS its own step (gesture + tweak1 = 2); got "
        ~ inSessionCount().to!string);
    auto v0AfterT1 = vert(0);
    assert(!vertNear(v0AfterT1, v0AfterG),
        "tweak1 re-graded v0 vs post-gesture");

    // DISCRETE tweak2: widen 3→6. P-E: a SEPARATE /api command = its own
    // generation → APPENDS a SECOND step (NOT REPLACE) → 3 in-session steps.
    cmd(`tool.pipe.attr falloff size "6,6,6"`);
    settle();
    assert(inSessionCount() == 3,
        "tweak2 is a DISCRETE tweak so it APPENDS its own step (gesture + tweak1 "
        ~ "+ tweak2 = 3) — drag + 2 discrete tweaks = 3 steps (G2); got "
        ~ inSessionCount().to!string);
    auto v0AfterT2 = vert(0);
    assert(!vertNear(v0AfterT2, v0AfterT1),
        "tweak2 re-graded v0 further vs after-tweak1");

    // The two refire entries carry DIFFERENT tweakGen tokens — the concrete
    // P-E discriminator that made tweak2 APPEND rather than REPLACE.
    auto gens = refireTweakGens();
    assert(gens.length == 2,
        "two tagged refire entries (one per discrete tweak); got "
        ~ gens.length.to!string);
    assert(gens[0] != gens[1],
        "the two DISCRETE tweaks carry DIFFERENT tweak generations (the P-E "
        ~ "discriminator that forced an APPEND); got [" ~ gens[0].to!string
        ~ ", " ~ gens[1].to!string ~ "]");

    // ONE in-session Ctrl+Z pops the LAST step (tweak2). Per OBJ-3 the re-grade
    // entry's before[] is the once-per-window post-gesture anchor, so the geometry
    // reverts straight to POST-GESTURE (v0AfterG), NOT to after-tweak1 — the
    // intermediate tweak1 is NOT a geometry waypoint, it is a distinct UNDO STEP
    // (witnessed by the floor+3 count above). The pop bumps mutationVersion, so
    // the wrapper's idle mutation guard then consolidates the surviving run
    // (gesture + tweak1) into the lone entry, floor+1 — the (R-F)-documented
    // closed-run behaviour.
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "ONE in-session Ctrl+Z popped the last step → geometry reverts to the "
        ~ "post-gesture anchor (OBJ-3 once-per-window anchor); got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(undoCount() == floor + 1,
        "the geometry-reverting pop closes the run → it consolidates to the lone "
        ~ "surviving gesture (floor+1); got " ~ undoCount().to!string);

    // Drop + unwind back to the cube (the surviving consolidated run).
    cmd("tool.set move off");
    settle();
    drainHistory();
    settle();
    assertVertex(6, 0.5, 0.5, 0.5,
        "draining the run history reverts the move run to the cube");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}

// ===========================================================================
// (BUG-2 CONTINUOUS SCRUB CONFIG-RESTORE) An in-session Ctrl+Z of a CONTINUOUS
// falloff scrub restores the RUN-START config, NOT the penultimate-frame value.
//
// This is the regression P-C/P-E introduced and BUG-2 fixes. A continuous
// falloff-handle drag fires the re-grade EVERY frame and the frames REPLACE-
// coalesce into ONE in-session entry (P-E shared generation). The pre-recompute
// snapshot used to be re-read from `dragFalloff` every frame, but
// captureFalloffForDrag clobbers `dragFalloff` with the live (just-tweaked)
// packet on each frame — so the coalesced entry's PRE-tweak (revert) endpoint
// ended up as the PENULTIMATE frame's value (e.g. size 3), not the run-start
// value (size 1). An in-session Ctrl+Z then reverted geometry but left the
// falloff CONFIG (and the viewport falloff viz) stranded at the next-to-last
// scrub value. The fix snapshots the PRE-tweak config ONCE per re-fire window
// (the same point refireAnchor is captured, when it is still run-start) and
// reuses it for every frame's revert endpoint.
//
// Headless drive: /api/script?interactive=true raises the forms-interactive
// latch so the THREE size writes (1→3→6→9) SHARE one tweak generation and
// REPLACE-coalesce into ONE re-grade entry (the continuous path that a plain
// /api/command stream cannot exercise — every command is its own generation).
// We assert (1) the coalesce happened (inSession stays 2, not 4), (2) the live
// size landed at the LAST scrub value (9), then (3) one in-session Ctrl+Z
// reverts the live size all the way to the RUN-START value (1) — NOT the
// penultimate (6). Pre-fix this asserted 6; post-fix it asserts 1.
// ===========================================================================
unittest {
    establishCubeBaseline();
    cmd("tool.set move");
    configTightRadial();          // radial, size 1,1,1, centered at v6
    settle();
    long floor = undoCount();
    assert(queryFalloffSizeX() == 1.0, "pre-condition: run-start falloff size is 1");

    moveArrowGesture(floor + 1);
    assert(undoCount() == floor + 1, "move gesture records one in-session step");
    auto v0AfterG = vert(0);      // far corner, barely moved under the tight radius

    // CONTINUOUS scrub: three same-generation widenings 1→3→6→9. The first
    // re-grade APPENDS (its tail is the gesture, not a refire); the next two
    // REPLACE (tail is the prior refire at the SAME generation). Net: ONE
    // re-grade entry → inSession 2 (gesture + the one coalesced re-grade).
    pipeScrub([
        `tool.pipe.attr falloff size "3,3,3"`,
        `tool.pipe.attr falloff size "6,6,6"`,
        `tool.pipe.attr falloff size "9,9,9"`,
    ]);
    settle();
    assert(inSessionCount() == 2,
        "a CONTINUOUS scrub (shared generation) REPLACE-coalesces into ONE "
        ~ "re-grade entry (gesture + 1 = 2 in-session), NOT one per frame; got "
        ~ inSessionCount().to!string);
    assert(undoCount() == floor + 2,
        "the coalesced scrub added exactly ONE re-grade entry (floor+2); now="
        ~ undoCount().to!string);
    assert(queryFalloffSizeX() == 9.0,
        "the scrub left the live falloff size at the LAST value (9); got "
        ~ queryFalloffSizeX().to!string);
    auto v0Regraded = vert(0);
    assert(!vertNear(v0Regraded, v0AfterG),
        "the scrub re-graded geometry at idle (contract A)");

    // THE BUG-2 ASSERTION: one in-session Ctrl+Z restores the RUN-START config
    // (size 1), not the penultimate frame (size 6). Geometry reverts to the
    // post-gesture anchor in lockstep (OBJ-3 once-per-window anchor).
    playAndWait(ctrlZ(50.0));
    settle();
    assert(vertNear(vert(0), v0AfterG),
        "in-session Ctrl+Z reverts the scrub geometry to the post-gesture anchor; "
        ~ "got (" ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(queryFalloffSizeX() == 1.0,
        "BUG-2: in-session Ctrl+Z of a CONTINUOUS scrub restores the RUN-START "
        ~ "falloff size (1), NOT the penultimate-frame value (6); got "
        ~ queryFalloffSizeX().to!string);

    // In-session redo re-applies BOTH: geometry re-graded AND config back to the
    // LAST scrub value (9, the coalesced entry's POST endpoint).
    playAndWait(ctrlShiftZ(70.0));
    settle();
    assert(vertNear(vert(0), v0Regraded),
        "in-session redo re-applies the coalesced scrub geometry; got ("
        ~ vert(0)[0].to!string ~ "," ~ vert(0)[1].to!string ~ ","
        ~ vert(0)[2].to!string ~ ")");
    assert(queryFalloffSizeX() == 9.0,
        "in-session redo re-applies the coalesced scrub config to the LAST value "
        ~ "(9, the POST endpoint); got " ~ queryFalloffSizeX().to!string);

    cmd("tool.set move off");
    cmd("tool.pipe.attr falloff type none");
    drainHistory();
}
