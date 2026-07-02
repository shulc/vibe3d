// test_falloff_idle_refire.d — task 0179 / audit-2 F1 regression lock.
//
// `falloffPacketsEqual` used to be a hand-maintained field list that had
// drifted: it silently OMITTED `normal` (cylinder axis), `pickedRadius`
// (Element `dist`/Range), `connect`, `elementMode` (`mode`), and
// `anchorRing` — so an idle-session edit of any of those attrs (status-bar
// pulldown / property panel / HTTP `tool.pipe.attr`) did NOT refresh a
// live transform preview. `steps` (Selection) and `mapName` (VertexMap)
// had no packet field AT ALL, so they couldn't round-trip through the
// wrapper's re-grade undo/redo hooks.
//
// The fix (`FalloffConfig` sub-struct, embedded in both `FalloffStage` and
// `FalloffPacket` via `alias config this`) makes equality the compiler-
// generated `==` of the WHOLE config field-set — a strict superset of the
// old hand-listed comparison, so every previously-omitted field now
// participates.
//
// Each case below lands one committed Move-gizmo gesture (the ARM2 "committed
// gizmo gesture, run open" re-grade path documented in
// source/tools/xfrm_transform.d, the same live-preview path
// `test_falloff_refire_rs.d` already exercises for `size`), then idle-edits
// ONE previously-omitted attr via `tool.pipe.attr falloff <attr> <value>` and
// asserts `/api/model` changed. `mode` (`elementMode`) is the one exception:
// it is a pure click-time pick-restriction enum never read by
// `evaluateFalloff` (grep confirms no consumer in source/falloff.d), so an
// idle edit cannot move geometry — it is asserted instead via the in-session
// undo-stack witness (`inSessionCount()`), which still proves the equality
// fix recognises the config change and fires a re-grade.
//
// A final case re-grades `map` (mapName) mid-run, then does an in-session
// Ctrl+Z and asserts BOTH the geometry AND the `map` attr revert to their
// PRE-tweak value (the P-A config-restore contract, now covering the two
// newly-packet-backed fields).
//
// F1 BEFORE/AFTER (verified via a live probe instance during development,
// see task 0179 log): on the pre-fix `falloffPacketsEqual`, idle edits of
// `axis`/`dist`/`connect`/`anchorRing`/`steps`/`map` did NOT refresh the
// preview (the omitted fields never triggered the wrapper's re-grade
// comparison) and `map` never round-tripped through re-grade undo at all
// (no packet field existed). After the fix, every case below observably
// changes geometry (or the tagged in-session count, for `mode`) and the
// undo round-trip restores config alongside geometry.

import std.net.curl;
import std.json;
import std.math   : fabs, sqrt, PI;
import std.conv    : to;
import std.format  : format;

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

void settle() {
    import core.thread : Thread;
    import core.time   : msecs;
    Thread.sleep(150.msecs);
}

long undoCount() {
    return getJson("/api/history")["undo"].array.length;
}

long inSessionCount() {
    long n = 0;
    foreach (e; getJson("/api/history")["undo"].array)
        if (("inSession" in e.object) !is null && e["inSession"].boolean) ++n;
    return n;
}

double[3][] dumpVerts() {
    double[3][] vs;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        vs ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return vs;
}

bool approxEq(double a, double b, double eps = 1e-4) { return fabs(a - b) < eps; }

string falloffAttr(string key) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            return st["attrs"][key].str;
    assert(false, "WGHT stage missing");
}

// The live gizmo pivot (ActionCenterPacket.center) — the same point
// `tool.pipe.attr actionCenter userPlacedCenter` relocates.
Vec3 evalPivot() {
    auto c = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

// Land ONE committed +X move-arrow gesture against the CURRENT gizmo pivot.
// Verify-and-retry keyed on the undo count (a missed grab records nothing;
// a hit records exactly one committed entry) — same idiom as
// test_falloff_refire_rs.d's `scaleGestureOnAxis`/`rotateGestureOnRing`.
void moveGestureOnArrow(long wantCount, double dragPx = 60.0) {
    foreach (attempt; 0 .. 6) {
        settle();
        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        double ux, uy;
        int xa, ya;
        axisGrabPx(evalPivot(), vp, xa, ya, ux, uy);
        int xb = xa + cast(int)(dragPx * ux);
        int yb = ya + cast(int)(dragPx * uy);
        playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  xa, ya, xb, yb, 10));
        settle();
        if (undoCount() == wantCount) return;
    }
    assert(false, "move gesture did not land (undo count never reached "
        ~ wantCount.to!string ~ ")");
}

// SDL Ctrl+Z keystroke — the in-session undo path (navHistory), matching
// test_falloff_refire_rs.d's `ctrlZ`.
string ctrlZ(double t) {
    return format(
        `{"t":%g,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n"
      ~ `{"t":%g,"type":"SDL_KEYUP","sym":122,"scan":0,"mod":64,"repeat":0}` ~ "\n",
        t, t + 10.0);
}

// ===========================================================================
// (AXIS) Cylinder falloff `normal` (wire attr `axis`).
//
// center OFF the cube's symmetric centroid (0.2,0,0) breaks the cube's
// axis-swap symmetry (every corner is otherwise equidistant from any single
// coordinate axis through the origin) so switching axis Y -> X changes the
// per-vertex weight. size=(0.9,0.9,0.9), shape=linear.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type cylinder");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr falloff center "0.2,0,0"`);
    cmd(`tool.pipe.attr falloff size "0.9,0.9,0.9"`);
    cmd(`tool.pipe.attr falloff axis "0,1,0"`);
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto v0AfterG = dumpVerts()[0];

    cmd(`tool.pipe.attr falloff axis "1,0,0"`);
    settle();
    auto v0Regraded = dumpVerts()[0];
    assert(!approxEq(v0Regraded[0], v0AfterG[0], 1e-3),
        "idle axis change (cylinder normal) must refresh the preview (F1 fix); "
        ~ "v0.x was " ~ v0AfterG[0].to!string ~ ", still " ~ v0Regraded[0].to!string
        ~ " after axis Y->X");

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (DIST) Element falloff `pickedRadius` (wire attr `dist` / Range).
//
// Sphere anchored at v0 (via ACEN userPlacedCenter), radius 0.3 — far
// corner v6 sits outside it (distance sqrt(3) ~= 1.73), so it does not move.
// Widening the radius to 3.0 idle brings v6 into range.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto v6AfterG = dumpVerts()[6];
    assert(approxEq(v6AfterG[0], 0.5, 1e-3),
        "v6 must sit outside the tight 0.3 sphere (unmoved); got "
        ~ v6AfterG[0].to!string);

    cmd("tool.pipe.attr falloff dist 3.0");
    settle();
    auto v6Regraded = dumpVerts()[6];
    assert(!approxEq(v6Regraded[0], v6AfterG[0], 1e-3),
        "idle dist change (Element Range) must refresh the preview (F1 fix); "
        ~ "v6.x was " ~ v6AfterG[0].to!string ~ ", still "
        ~ v6Regraded[0].to!string ~ " after widening dist to 3.0");

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (ANCHOR-RING) Element falloff `anchorRing` short-circuit.
//
// Same tight-sphere setup as (DIST): v6 sits outside range and does not
// move. Idle-adding v6 to `anchorRing` short-circuits it to weight 1.0
// regardless of the sphere math (falloff.d elementWeight).
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 0.3");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto v6AfterG = dumpVerts()[6];
    assert(approxEq(v6AfterG[0], 0.5, 1e-3),
        "v6 must sit outside the tight 0.3 sphere (unmoved); got "
        ~ v6AfterG[0].to!string);

    cmd(`tool.pipe.attr falloff anchorRing "6"`);
    settle();
    auto v6Regraded = dumpVerts()[6];
    assert(!approxEq(v6Regraded[0], v6AfterG[0], 1e-3),
        "idle anchorRing change must refresh the preview (F1 fix): v6 should "
        ~ "short-circuit to weight 1.0; v6.x was " ~ v6AfterG[0].to!string
        ~ ", still " ~ v6Regraded[0].to!string ~ " after anchorRing=\"6\"");

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (CONNECT) Element falloff `connect` gate — needs a genuinely
// TWO-COMPONENT mesh (a single connected cube can't discriminate Ignore
// from UseConnectivity: one component covers everything). Mirrors
// test_falloff_element_connect.d's two-cube fixture.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:3 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:1 segmentsY:1 segmentsZ:1 radius:0");   // append -> verts 8..15
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd(`tool.pipe.attr falloff anchorRing "8"`);
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "2.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 5.0");   // large: whole mesh geometrically in range
    cmd("tool.pipe.attr falloff shape linear");
    cmd("tool.pipe.attr falloff connect ignore");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto v0AfterG = dumpVerts()[0];   // cube-A vertex, unconnected to the anchor
    assert(!approxEq(v0AfterG[0], -0.5, 1e-3),
        "Ignore: cube-A vert (in geometric range) should have moved; got "
        ~ v0AfterG[0].to!string);

    cmd("tool.pipe.attr falloff connect useConnectivity");
    settle();
    auto v0Regraded = dumpVerts()[0];
    assert(!approxEq(v0Regraded[0], v0AfterG[0], 1e-3),
        "idle connect change must refresh the preview (F1 fix): cube-A "
        ~ "should be gated back to 0 under UseConnectivity; v0.x was "
        ~ v0AfterG[0].to!string ~ ", still " ~ v0Regraded[0].to!string
        ~ " after connect=useConnectivity");
    assert(approxEq(v0Regraded[0], -0.5, 1e-3),
        "UseConnectivity must gate the unconnected cube-A vert fully back to "
        ~ "its unmoved position; got " ~ v0Regraded[0].to!string);

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (MODE) Element falloff `elementMode` (wire attr `mode`) is a pure
// click-pick restriction — grep of source/falloff.d confirms `elementMode`
// is never read by evaluateFalloff/elementWeight, only by
// XfrmTransformTool's interactive click-pick (source/tools/xfrm_transform.d).
// An idle edit of `mode` therefore CANNOT move geometry — but the F1 fix
// means the config-equality check now recognises the change and fires a
// re-grade anyway (the packet is genuinely unequal). Witnessed via the
// in-session undo-stack tag, not a geometry delta.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(`tool.pipe.attr actionCenter userPlacedCenter "-0.5,-0.5,-0.5"`);
    cmd("tool.pipe.attr falloff dist 3.0");
    cmd("tool.pipe.attr falloff mode auto");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    assert(inSessionCount() >= 1,
        "the landed move gesture must be a tagged in-session entry");
    long beforeModeEdit = inSessionCount();

    cmd("tool.pipe.attr falloff mode vertex");
    settle();
    assert(inSessionCount() > beforeModeEdit,
        "idle `mode` (elementMode) change must fire a re-grade (F1 fix): "
        ~ "config equality now includes elementMode even though it carries "
        ~ "no weight-math effect; inSessionCount was " ~ beforeModeEdit.to!string
        ~ ", still " ~ inSessionCount().to!string ~ " after mode=vertex");

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (STEPS) Selection falloff `steps` — needs an INTERIOR selected vertex, so
// a subdivided cube (prim.cube with segments) is required (a plain cube's
// 1-face selection is all-boundary, see test_xfrm_flex.d). Select the top
// 4x4 face grid (16 quads, faces 48..63 for a 4-segment cube) — a 5x5
// vertex grid with a genuine 3x3 interior. `steps` going from a shallow 1
// (interior barely diffused, near saturation) to a wide 6 (many more
// smoothing passes — the diffusion decays interior weight toward the
// pinned-0 border, see FalloffStage's `steps` field doc) changes the
// centre vertex's weight dramatically.
// ===========================================================================
unittest {
    postJson("/api/reset?empty=true", "");
    cmd("select.typeFrom polygon");
    cmd("prim.cube cenX:0 cenY:0 cenZ:0 sizeX:1 sizeY:1 sizeZ:1 "
        ~ "segmentsX:4 segmentsY:4 segmentsZ:4 radius:0");
    postJson("/api/select",
        `{"mode":"polygons","indices":[48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63]}`);
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type selection");
    cmd("tool.pipe.attr falloff steps 1");
    cmd("tool.pipe.attr falloff shape smooth");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    // vertex 72 is the exact centre of the selected top face (0,0.5,0)
    // before the gesture — a well-known index for this fixture geometry.
    auto centreAfterG = dumpVerts()[72];

    cmd("tool.pipe.attr falloff steps 6");
    settle();
    auto centreRegraded = dumpVerts()[72];
    assert(!approxEq(centreRegraded[0], centreAfterG[0], 1e-3),
        "idle steps change (Selection falloff) must refresh the preview "
        ~ "(F1 fix): centre-vert.x was " ~ centreAfterG[0].to!string
        ~ ", still " ~ centreRegraded[0].to!string ~ " after steps 1->6");

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (MAP) VertexMap falloff `mapName` (wire attr `map`) — had NO packet field
// at all pre-fix, so it could not even be COMPARED, let alone re-grade.
// Two weight maps each isolate a different single vertex to weight 1.0;
// switching the active map idle must re-grade both verts.
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    postJson("/api/command", `{"id":"mesh.weightmap.create","params":{"name":"wmA"}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.set","params":{"name":"wmA","vert":0,"weight":1.0}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.create","params":{"name":"wmB"}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.set","params":{"name":"wmB","vert":1,"weight":1.0}}`);
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map wmA");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto verts = dumpVerts();
    auto v0AfterG = verts[0];   // weight 1.0 under wmA -> moved
    auto v1AfterG = verts[1];   // weight 0.0 under wmA -> unmoved
    assert(!approxEq(v0AfterG[0], -0.5, 1e-3), "v0 (wmA weight=1.0) should have moved");
    assert(approxEq(v1AfterG[0], 0.5, 1e-3),   "v1 (wmA weight=0.0) should not have moved");

    cmd("tool.pipe.attr falloff map wmB");
    settle();
    auto v0Regraded = dumpVerts()[0];
    auto v1Regraded = dumpVerts()[1];
    assert(!approxEq(v0Regraded[0], v0AfterG[0], 1e-3),
        "idle map change must refresh the preview (F1 fix): v0 should be "
        ~ "gated back to unmoved under wmB (weight 0.0); v0.x was "
        ~ v0AfterG[0].to!string ~ ", still " ~ v0Regraded[0].to!string);
    assert(!approxEq(v1Regraded[0], v1AfterG[0], 1e-3),
        "v1 should now move under wmB (weight 1.0); v1.x was "
        ~ v1AfterG[0].to!string ~ ", still " ~ v1Regraded[0].to!string);

    cmd("tool.set move off");
    postJson("/api/reset", "");
}

// ===========================================================================
// (RE-GRADE UNDO) In-session Ctrl+Z of a `map` re-grade restores BOTH the
// geometry AND the `map` config value to its PRE-tweak state (the P-A
// config-restore contract, now covering the two newly-packet-backed fields
// steps/mapName — task 0179 DoD item).
// ===========================================================================
unittest {
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    postJson("/api/command", `{"id":"mesh.weightmap.create","params":{"name":"wmA"}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.set","params":{"name":"wmA","vert":0,"weight":1.0}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.create","params":{"name":"wmB"}}`);
    postJson("/api/command", `{"id":"mesh.weightmap.set","params":{"name":"wmB","vert":1,"weight":1.0}}`);
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type vertexMap");
    cmd("tool.pipe.attr falloff map wmA");
    settle();
    long floor = undoCount();

    moveGestureOnArrow(floor + 1);
    auto v0AfterG = dumpVerts()[0];
    assert(falloffAttr("map") == "wmA", "pre-tweak map attr should read back wmA");

    cmd("tool.pipe.attr falloff map wmB");
    settle();
    auto v0Regraded = dumpVerts()[0];
    assert(!approxEq(v0Regraded[0], v0AfterG[0], 1e-3),
        "map re-grade must change v0's geometry before the undo check");
    assert(falloffAttr("map") == "wmB", "post-tweak map attr should read back wmB");

    playAndWait(ctrlZ(50.0));
    settle();
    auto v0Undone = dumpVerts()[0];
    assert(approxEq(v0Undone[0], v0AfterG[0], 1e-3),
        "in-session Ctrl+Z of the map re-grade must restore the PRE-tweak "
        ~ "geometry; expected v0.x=" ~ v0AfterG[0].to!string ~ ", got "
        ~ v0Undone[0].to!string);
    assert(falloffAttr("map") == "wmA",
        "in-session Ctrl+Z must also restore the PRE-tweak `map` CONFIG "
        ~ "(steps/mapName now round-trip through the packet — task 0179); "
        ~ "got " ~ falloffAttr("map"));

    cmd("tool.set move off");
    postJson("/api/reset", "");
}
