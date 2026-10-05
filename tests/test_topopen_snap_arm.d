// Topology Pen — ACTIVATING THE TOOL ARMS THE APPLICATION-WIDE SNAP ENABLE,
// and dropping it hands the previous value back.
//
// MEASURED, and the attribution is the INVOCATION rather than the tool or its
// composition: the reference's tool-activation command carries a fourth
// argument meaning "snap state at startup", every one of the twelve shipped UI
// routes to its pen supplies it, and supplying it pushes the previous app-
// global snap state before writing the new one. The drop restores it because
// the drop path is a re-invocation of the same command. Three negative
// controls rule out the alternatives — a sibling retopology preset OMITS the
// argument, a pen preset that composes no snap tool at all still arms, and the
// "bring your own snap preset" atom sits on presets that both do and do not
// compose one. See `source/tools/edit/topology_pen/tool.d`'s `armStartupSnap`.
//
// WHY IT MATTERS, and why this file exists rather than a unittest alone: that
// global IS the weld gate. Every Move-family release now resolves a weld
// target per moved vertex and ABSORBS the grab into anything inside the
// acceptance radius — with no setting touched by the user. This file pins both
// halves through the real HTTP surface: the lifecycle (§1) and the destructive
// consequence with its undo granularity (§2).
//
// The rig in §2 is test_topopen_move_element_drag.d's, for its reasons: a
// dense sphere BACKGROUND (layer 0) that Move re-snaps onto, and a quad
// PRIMARY (layer 1) whose four corners are all BORDER vertices — which is the
// candidate set `innerSnap` admits at its default OFF, i.e. the configuration
// the reference's plain pen button ships in.
//
// Run via: ./run_test.d topopen_snap_arm

import http_client : quiesce;
import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs, lround, tan, PI;
import std.format : format;
import std.file   : readText;
import drag_helpers : viewportFromCameraMatrices, pixelRay, buildDragDownLog,
                     buildDragMotionLog, buildDragUpLog;

void main() {}

enum float  R    = 2.0f;
enum int    LON  = 96, LAT = 72;   // resolution rationale: topopen_place_helpers.d
enum float  kQuadHalf = 0.75f;     // a 1.5x1.5 quad, well inside the R=2 sphere

/// The snap ACCEPTANCE radius the weld reads (`SnapStage.innerRangePx`, and
/// `SnapPacket.init`'s copy of it — pinned equal by a unittest in
/// `toolpipe/stages/snap.d`). Mirrored here so §2's preconditions are stated
/// in the units the code under test uses.
enum float kAcceptPx = 24.0f;

/// The master snap enable, read back off the live pipeline rather than
/// inferred from behaviour.
bool snapEnabled() {
    foreach (s; getJson("/api/toolpipe")["stages"].array)
        if (s["id"].str == "snap")
            return s["attrs"]["enabled"].str == "true";
    assert(false, "the SNAP stage must be registered in the pipeline");
}

size_t undoDepth() {
    return getJson("/api/history")["undo"].array.length;
}

bool sameVec(double[] a, double[] b, double tol) {
    return abs(a[0] - b[0]) < tol && abs(a[1] - b[1]) < tol && abs(a[2] - b[2]) < tol;
}

// ---------------------------------------------------------------------------
// §1 — THE LIFECYCLE.
//
// Six cells, each a claim someone could get wrong independently:
//
//   A  the shipped default is OFF. Without this the rest is unfalsifiable.
//   B  activating the pen ARMS it. The user-visible change.
//   C  dropping the pen RESTORES the value it was given — a global must not be
//      left flipped by having touched a tool once.
//   D  a user who ALREADY had snapping on keeps it on across the pen. A
//      restore that wrote a constant would silently switch snapping off for
//      that user on every drop.
//   E  a tool SWITCH restores too — the drop half runs on deactivate, not only
//      on an explicit `off`.
//   F  another tool does NOT arm. This is the pen's activation, not a global
//      default change: `SnapStage.enabled` still ships false and its six other
//      consumers are untouched.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/command", commandBody("scene.reset"));

    // A
    assert(!snapEnabled(),
        "the shipped default must still be snapping OFF — this change arms the "
        ~ "enable from the pen's activation, it does not move the field's default");

    // B
    cmd("tool.set mesh.topoPen on");
    assert(snapEnabled(),
        "activating the pen must arm the application-wide snap enable — that is "
        ~ "the weld gate, and every shipped route to the reference's pen arms it");

    // C
    cmd("tool.set mesh.topoPen off");
    assert(!snapEnabled(),
        "dropping the pen must hand back the OFF it was given");

    // D
    cmd("tool.pipe.attr snap enabled true");
    assert(snapEnabled(), "setup: the user turned snapping on");
    cmd("tool.set mesh.topoPen on");
    assert(snapEnabled());
    cmd("tool.set mesh.topoPen off");
    assert(snapEnabled(),
        "a user who already had snapping ON must still have it ON after the pen "
        ~ "is dropped — the restore writes the SAVED value, never a constant");

    // E
    postJson("/api/command", commandBody("scene.reset"));
    assert(!snapEnabled(), "setup: reset returns the clean slate");
    cmd("tool.set mesh.topoPen on");
    assert(snapEnabled(), "setup: armed");
    cmd("tool.set move on");
    assert(!snapEnabled(),
        "switching to another tool drops the pen, and the drop must restore — "
        ~ "otherwise the pen leaves snapping armed under every tool that follows");

    // F
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.set move on");
    assert(!snapEnabled(),
        "a tool that is not the pen must not arm snapping — this is the pen's "
        ~ "own activation, not a change to the shipped default");
    cmd("tool.set move off");
    postJson("/api/command", commandBody("scene.reset"));
}

// ---------------------------------------------------------------------------
// §1b — A SCENE RESET WINS OVER THE PENDING RESTORE.
//
// ORDERING, not hygiene: `/api/reset` resets every pipe stage BEFORE it drops
// the active tool, so the drop's restore arrives AFTER the clean slate. If the
// saved value survived the reset it would be written back on top, leaving
// snapping armed across a reset and bleeding into whatever runs next in the
// same process — the runner reuses one vibe3d per worker, so that is a
// cross-test failure waiting to happen.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/command", commandBody("scene.reset"));
    cmd("tool.pipe.attr snap enabled true");   // user had snapping on ...
    cmd("tool.set mesh.topoPen on");           // ... and the pen armed over it
    assert(snapEnabled(), "setup: armed");

    postJson("/api/command", commandBody("scene.reset"));
    assert(!snapEnabled(),
        "a scene reset must leave snapping OFF even though the tool it dropped "
        ~ "had a restore pending — otherwise the pre-reset value is written back "
        ~ "over the clean slate");
}

// ---------------------------------------------------------------------------
// §2 — THE DESTRUCTIVE CONSEQUENCE, AT THE DEFAULT CONFIGURATION.
//
// No snap setting is touched by this test. It activates the pen exactly as the
// UI does, drags one quad corner onto a neighbouring corner, and the grab is
// ABSORBED: four vertices become three, and the survivor sits at the TARGET's
// own position (the target survives, the grab disappears — task 0555's measured
// polarity). Before this change the same drag left four vertices and a
// coincident pair.
//
// AND IT IS STILL ONE UNDO STEP. The absorption rides the SAME history entry
// the move does, so the whole gesture — press, N motion events, release, weld —
// is one Ctrl+Z. That was already the contract for a plain Move; this pins it
// on the weld path, which was unreachable in the default configuration until
// now.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/command", commandBody("scene.reset"));
    setupSphereBg(R, LON, LAT);

    auto lq = postJson("/api/command", commandBody("scene.loadMesh", format(
        `{"vertices":[[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0],[%.4f,%.4f,0.0]],`
      ~ `"faces":[[0,1,2,3]]}`,
        -kQuadHalf, -kQuadHalf,  kQuadHalf, -kQuadHalf,
         kQuadHalf,  kQuadHalf, -kQuadHalf,  kQuadHalf)));
    assert(lq["status"].str == "ok", "load-mesh (primary quad) failed: " ~ lq.toString);
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        "setup: the primary layer must hold exactly the quad");

    // Camera LAST — `/api/load-mesh` restores the post-load camera.
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    // NOTHING ELSE IS SET. In particular `innerSnap` stays at its default OFF
    // (border-only candidates — every quad corner qualifies) and snapping is
    // never enabled by this test: the activation above is the whole of it.
    assert(snapEnabled(),
        "setup: the activation alone must have armed the gate — if it has not, "
        ~ "the rest of this test would pass vacuously by never welding");

    auto before = readVerticesLayer(1);
    float[4] qx, qy;
    foreach (i; 0 .. 4) {
        float sx, sy;
        assert(projectToWindow(Vec3(cast(float)before[i][0], cast(float)before[i][1],
                                    cast(float)before[i][2]), vp, sx, sy),
            format("setup: quad corner %d must project on-screen", i));
        qx[i] = sx; qy[i] = sy;
    }
    // Corners 0 and 1 must start FARTHER apart than the acceptance radius, or
    // the grab would already be inside its target and the drag would prove
    // nothing about having brought it there.
    immutable float sep = sqrt((qx[0] - qx[1]) * (qx[0] - qx[1])
                             + (qy[0] - qy[1]) * (qy[0] - qy[1]));
    assert(sep > kAcceptPx * 1.5f,
        format("setup: corners 0 and 1 must start well outside the %.0fpx acceptance "
             ~ "radius; got %.1fpx", kAcceptPx, sep));

    immutable size_t undo0 = undoDepth();

    // Grab corner 0 and release ON corner 1's pixel — distance 0, so inside
    // the acceptance radius by any reading of it.
    auto pr = postJson("/api/play-events",
        buildDragLog(c.vpX, c.vpY, c.width, c.height,
                     cast(int)qx[0], cast(int)qy[0],
                     cast(int)qx[1], cast(int)qy[1], 16, 0, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(1) == 3,
        format("a drag released on a neighbouring vertex must ABSORB the grab — "
             ~ "with the gate armed by the pen's own activation and no setting "
             ~ "touched. Expected 4 -> 3 vertices, got %d", vertexCountLayer(1)));

    // The TARGET survives at its OWN position; the grab is what disappears.
    auto after = readVerticesLayer(1);
    bool targetSurvived = false;
    foreach (v; after)
        if (sameVec(v, before[1], 1e-5)) { targetSurvived = true; break; }
    assert(targetSurvived,
        format("the weld TARGET must survive at its own position %s — the grab is "
             ~ "the vertex that disappears, not the target", before[1]));
    // And the grab is GONE rather than merely coincident. Independent of the
    // count: a vertex grab re-snaps onto the background SPHERE, so had the
    // absorption not fired there would be a survivor at radius R while every
    // quad corner sits at |(+-0.75, +-0.75, 0)| ~ 1.06. Nothing on the sphere
    // means nothing survived the landing.
    foreach (v; after) {
        immutable double r = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        assert(abs(r - R) > 0.2,
            format("a survivor at radius %.4f is the grabbed vertex left at its "
                 ~ "re-snap landing point on the background sphere — the weld "
                 ~ "did not fire", r));
    }

    // ONE undo step for the whole gesture, weld included.
    assert(undoDepth() == undo0 + 1,
        format("the whole gesture — press, motion events, release AND the weld — "
             ~ "must be ONE undo entry, not one per motion event and not a second "
             ~ "entry for the absorption; depth %d -> %d", undo0, undoDepth()));

    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    assert(vertexCountLayer(1) == 4 && edgeCountLayer(1) == 4 && faceCountLayer(1) == 1,
        format("a single undo must restore the whole quad, topology included; got "
             ~ "%d verts / %d edges / %d faces",
               vertexCountLayer(1), edgeCountLayer(1), faceCountLayer(1)));
    auto restored = readVerticesLayer(1);
    foreach (i; 0 .. 4)
        assert(sameVec(restored[i], before[i], 1e-5),
            format("undo must restore corner %d exactly: want %s, got %s",
                   i, before[i], restored[i]));

    cmd("tool.set mesh.topoPen off");
    postJson("/api/command", commandBody("scene.reset"));
}

// ---------------------------------------------------------------------------
// §3 — THE WELD TARGET OBEYS THE SNAP SERVICE'S MASKS (captured, batch K-T;
// fixture tests/fixtures/topopen_weld_targets.json).
//
// A move-mode drag of vertex b released 6 px from vertex a, in a top
// orthographic view at the capture's 0.002275 m/px. The weld target is the
// snap query's answer (`TopologyPenTool.weldTargetVertex`): a vertex OCCLUDED
// by a closed box, a HIDDEN vertex, and a vertex of a BACKGROUND mesh are not
// weld targets. Each scene runs its CONTROL first (the same drag welds), so a
// refusal below is the mask and not a broken rig.
//
// ONE RIG DIFFERENCE: our vertex move lands on the background hit and does
// not move at all without a background, so every scene adds a background
// plane at the meshes' height (y 1) under the drag. A refused weld therefore
// leaves b at the plane hit under the release pixel, not at the capture's
// quantised-offset reading (fixture `b_final`), which this rig cannot produce.
// ---------------------------------------------------------------------------

enum double kWeldPs = 0.002275;   // the capture's metres per pixel

JSONValue weldFixture() {
    return parseJSON(readText("tests/fixtures/topopen_weld_targets.json"));
}

double[3][] fixtureQuad(string key) {
    double[3][] q;
    foreach (p; weldFixture()[key].array)
        q ~= [p[0].get!double, p[1].get!double, p[2].get!double];
    return q;
}

JSONValue weldCell(string id) {
    foreach (c; weldFixture()["cells"].array)
        if (c["id"].str == id) return c;
    assert(false, "no fixture cell " ~ id);
}

double[3][] quadAt(double x0, double x1, double z0, double z1) {
    return [[x0, 1.0, z0], [x0, 1.0, z1], [x1, 1.0, z1], [x1, 1.0, z0]];
}

string meshBody(double[3][] v, int[][] f) {
    string s = `{"vertices":[`;
    foreach (i, p; v) s ~= format(`%s[%.6f,%.6f,%.6f]`, i ? "," : "", p[0], p[1], p[2]);
    s ~= `],"faces":[`;
    foreach (i, q; f) s ~= format(`%s%s`, i ? "," : "", q);
    return s ~ `]}`;
}

void loadLayerMesh(double[3][] v, int[][] f) {
    auto r = postJson("/api/command", commandBody("scene.loadMesh", meshBody(v, f)));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
}

/// One K-T scene in layer 1 over a background plane in layer 0, camera and
/// pen armed (`snapAttrs` are `tool.pipe.attr snap` lines set before the arm).
/// `scene`: "occ", "occctl", "hid", "hidctl", "bg", "bgctl". Returns b's index.
int weldScene(string scene, string[] snapAttrs = null) {
    double[3][] A = fixtureQuad("A_quad"), B = fixtureQuad("B_quad");
    double[3][] Y = quadAt(0.9, 1.2, -0.6, -0.3);   // a far bystander quad
    int[][] q2 = [[0, 1, 2, 3], [4, 5, 6, 7]];

    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(r["status"].str == "ok", "empty reset failed: " ~ r.toString);
    double[3][] bg = quadAt(-1.0, 1.4, -0.9, 1.0);    // the landing plane
    int[][] bgF = [[0, 1, 2, 3]];
    if (scene == "bg")    { bg ~= A; bgF ~= [4, 5, 6, 7]; }
    if (scene == "bgctl") { bg ~= Y; bgF ~= [4, 5, 6, 7]; }
    loadLayerMesh(bg, bgF);
    cmd("layer.add name:Edit");
    int bIdx = 4;
    if (scene == "occ" || scene == "occctl") {
        immutable double y0 = scene == "occ" ? 1.2 : 0.5, y1 = scene == "occ" ? 1.5 : 0.8;
        double[3][] box = [[0.15, y0, 0.15], [0.45, y0, 0.15], [0.45, y1, 0.15], [0.15, y1, 0.15],
                           [0.15, y0, 0.45], [0.45, y0, 0.45], [0.45, y1, 0.45], [0.15, y1, 0.45]];
        int[][] f = q2;
        foreach (c; [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]])
            f ~= [c[0] + 8, c[1] + 8, c[2] + 8, c[3] + 8];
        loadLayerMesh(A ~ B ~ box, f);
    } else if (scene == "hid" || scene == "hidctl") {
        loadLayerMesh(A ~ B ~ Y, q2 ~ [[8, 9, 10, 11]]);
        cmd(commandBody("mesh.select", format(`{"mode":"vertices","indices":[%d]}`,
                                               scene == "hid" ? 0 : 8)));
        cmd(`{"id":"mesh.hide"}`);
        cmd(commandBody("select.drop"));
    } else if (scene == "bg") {
        loadLayerMesh(B ~ Y, q2);
        bIdx = 0;
    } else {
        loadLayerMesh(A ~ B, q2);
    }
    assert(vertexCountLayer(1) == weldCell("weld-" ~ scene)["fg_vertex_count"].array[0].integer,
        "rig: the edited mesh must hold the fixture's vertex count");
    cmd("history.clear");
    cmd("workplane.reset");
    cmd("viewport.view Top");
    immutable double dist = fetchCamera().height / (2.0 * (1.0 / kWeldPs) * tan(PI / 8));
    auto cr = postJson("/api/camera", format(
        `{"focus":{"x":0.07,"y":1.0,"z":0.0},"distance":%.9f}`, dist));
    assert(cr["status"].str == "ok", "camera setup failed: " ~ cr.toString);
    assert(getJson("/api/camera")["projKind"].str == "Ortho", "rig: the top view must be ortho");
    cmd(`tool.pipe.attr snap types ""`);   // every global snap type OFF, as captured
    foreach (a; snapAttrs) cmd("tool.pipe.attr snap " ~ a);
    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    cmd("tool.attr mesh.topoPen backFace true");
    assert(snapEnabled(), "rig: the pen's activation arms the snap enable");
    return bIdx;
}

/// Press on b, drag by the captured pointer delta (+ `extraDx` px), release.
/// Returns the plane hit (y 1) under the release pixel's centre.
double[3] weldDrag(int bIdx, int extraDx = 0) {
    auto vp = viewportFromCameraMatrices();
    auto b = readVerticesLayer(1)[bIdx];
    float sx, sy;
    assert(projectToWindow(Vec3(cast(float)b[0], cast(float)b[1], cast(float)b[2]), vp, sx, sy),
        "rig: b must project");
    immutable int x0 = cast(int)lround(sx), y0 = cast(int)lround(sy);
    immutable int x1 = x0 + 271 + extraDx, y1 = y0 + 219;
    auto pr = postJson("/api/play-events", buildDragLog(vp.x, vp.y, vp.width, vp.height,
        x0, y0, x1, y1, 16, 0, 1));
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();
    Vec3 org, dir;
    pixelRay(x1 + 0.5f, y1 + 0.5f, vp, org, dir);   // the pixel centre the hit reads
    immutable float t = (1.0f - org.y) / dir.y;
    return [org.x + t * dir.x, 1.0, org.z + t * dir.z];
}

/// Assert the fixture cell's outcome on the edited layer; `landing` is where
/// an unwelded b must sit.
void assertWeldCell(string id, int bIdx, double[3] landing) {
    auto c = weldCell(id);
    immutable long n1 = c["fg_vertex_count"].array[1].integer;
    assert(vertexCountLayer(1) == n1, format("%s: vertex count %d, expected %d (%s)",
        id, vertexCountLayer(1), n1, c["result"].str));
    if (c["result"].str == "WELD") {
        assert(hasExactFace(1, [0, 4, 5, 6]),
            format("%s: the welded ring must be [0,4,5,6], got %s", id, readFacesLayer(1)));
        return;
    }
    auto got = readVerticesLayer(1)[bIdx];
    foreach (k; 0 .. 3)
        assert(abs(got[k] - landing[k]) <= 1e-4, format(
            "%s: a refused weld leaves b at its landing %s, got %s", id, landing, got));
}

unittest { // occluded: control (box below a) welds, box between a and the eye refuses
    int bIdx = weldScene("occctl");
    assertWeldCell("weld-occctl", bIdx, weldDrag(bIdx));
    bIdx = weldScene("occ");
    assertWeldCell("weld-occ", bIdx, weldDrag(bIdx));
    cmd("tool.set mesh.topoPen off");
}

unittest { // hidden: control (bystander hidden) welds, a hidden refuses
    int bIdx = weldScene("hidctl");
    assertWeldCell("weld-hidctl", bIdx, weldDrag(bIdx));
    bIdx = weldScene("hid");
    assertWeldCell("weld-hid", bIdx, weldDrag(bIdx));
    cmd("tool.set mesh.topoPen off");
}

unittest { // background: control (a in the edited mesh) welds, a in a background mesh refuses
    int bIdx = weldScene("bgctl");
    assertWeldCell("weld-bgctl", bIdx, weldDrag(bIdx));
    bIdx = weldScene("bg");
    auto bg0 = readVerticesLayer(0);
    assertWeldCell("weld-bg", bIdx, weldDrag(bIdx));
    assert(readVerticesLayer(0) == bg0, "weld-bg: the background mesh must be unchanged");
    cmd("tool.set mesh.topoPen off");
}

unittest { // law-neutral: the weld ignores the snap SCOPE and reaches the whole accept radius
    // weld-scope-item: the snap scope at Item, the occluded scene's control still welds.
    int bIdx = weldScene("occctl", ["snapMode item"]);
    assertWeldCell("weld-occctl", bIdx, weldDrag(bIdx));
    cmd("tool.set mesh.topoPen off");
    cmd("tool.pipe.attr snap snapMode global");

    // weld-accept-above-outer: an inner range (60 px) above the 40 px outer range;
    // a release 45 px from a still welds.
    bIdx = weldScene("occctl", ["innerRange 60"]);
    assertWeldCell("weld-occctl", bIdx, weldDrag(bIdx, -39));
    cmd("tool.set mesh.topoPen off");
    cmd("tool.pipe.attr snap innerRange 24");

    // weld-beyond-accept: at the shipped 24 px a release 30 px from a refuses
    // (the acceptance is the radius; capture K-P P6, task 9437).
    bIdx = weldScene("occctl");
    immutable long before = vertexCountLayer(1);
    weldDrag(bIdx, -24);
    assert(vertexCountLayer(1) == before, format(
        "weld-beyond-accept: vertex count %d -> %d, a 30 px release must not weld",
        before, vertexCountLayer(1)));
    cmd("tool.set mesh.topoPen off");
    postJson("/api/command", commandBody("scene.reset"));
}

// ---------------------------------------------------------------------------
// §4 — SAME-POLYGON CORNERS (captured, KW2J-PEN, task 9486): the move weld is
// Drag Weld's pair weld. Adjacent corners collapse the edge (KJP_A, as KW2_I);
// DIAGONAL corners weld anyway, the target wins and the quad keeps four corners
// [a,T,b,T] (KJP_D, bit-equal to KW2_J). Front ortho at 0.01 m/px, snap on with
// every global type off; a background plane at z 0 is the landing surface.
// ---------------------------------------------------------------------------

/// Load `pts` (one quad unless `faces`) in layer 1, move v1 (or the element under
/// `press`) by (`dx`,`dy`) px with the pen; `sym` turns world symmetry X on. The first
/// gesture's motion passes through the px offsets `stops`; `probe(k)` runs held after
/// the press (k 0), at each stop and at the motion's end (k 1 .. stops.length + 1), and
/// after the release (k stops.length + 2).
void sameQuadMove(double[3][] pts, double[3] release, int dx, int dy,
                  int[][] faces = [[0, 1, 2, 3]], bool sym = false, double[] press = null,
                  int[] hide = null, int gestures = 1, int[2][] stops = null,
                  void delegate(size_t) probe = null) {
    immutable bool grabV1 = press is null;
    if (grabV1) press = pts[1].dup;
    auto r = postJson("/api/command", commandBody("scene.reset", `{"empty":true}`));
    assert(r["status"].str == "ok", "empty reset failed: " ~ r.toString);
    loadLayerMesh([[-2.0, -2.0, 0.0], [2.0, -2.0, 0.0], [2.0, 2.0, 0.0], [-2.0, 2.0, 0.0]],
                  [[0, 1, 2, 3]]);
    cmd("layer.add name:Edit");
    loadLayerMesh(pts, faces);
    if (hide.length) {
        cmd(commandBody("mesh.select", format(`{"mode":"vertices","indices":%s}`, hide)));
        cmd(`{"id":"mesh.hide"}`);
        cmd(commandBody("select.drop"));
    }
    cmd("history.clear");
    cmd("workplane.reset");
    cmd("viewport.view Front");
    immutable double dist = fetchCamera().height / (2.0 * 100.0 * tan(PI / 8));
    auto cr = postJson("/api/camera", format(
        `{"focus":{"x":-0.15,"y":0.18,"z":0.0},"distance":%.9f}`, dist));
    assert(cr["status"].str == "ok", "camera setup failed: " ~ cr.toString);
    cmd(`tool.pipe.attr snap types ""`);
    if (sym) foreach (c; ["axis x", "offset 0", "enabled true"]) cmd("tool.pipe.attr symmetry " ~ c);
    cmd("tool.set mesh.topoPen on");
    cmd("tool.attr mesh.topoPen mode move");
    assert(snapEnabled(), "rig: the pen's activation arms the snap enable");
    auto vp = viewportFromCameraMatrices();
    float sx, sy, ex, ey;
    assert(projectToWindow(Vec3(cast(float)press[0], cast(float)press[1], 0), vp, sx, sy)
        && projectToWindow(Vec3(cast(float)release[0], cast(float)release[1], 0), vp, ex, ey),
        "rig: the press and the release must project");
    int x0 = cast(int)lround(sx), y0 = cast(int)lround(sy);
    assert(lround(ex) == x0 + dx && lround(ey) == y0 + dy,
        format("rig: the captured %s px drag must end at %s", [dx, dy], release));
    foreach (g; 0 .. gestures) {   // each next gesture, same session: the same drag on again
    string[] logs = [buildDragDownLog(vp.x, vp.y, vp.width, vp.height, x0, y0)];
    int[2] at = [0, 0], end = [dx, dy];
    foreach (leg; (g ? null : stops) ~ end) {
        logs ~= buildDragMotionLog(vp.x, vp.y, vp.width, vp.height, x0 + at[0], y0 + at[1],
                                   x0 + leg[0], y0 + leg[1], 16);
        at = leg;
    }
    logs ~= buildDragUpLog(vp.x, vp.y, vp.width, vp.height, x0 + dx, y0 + dy);
    foreach (i, log; logs) {
        if (probe !is null && g == 0 && i > 0) probe(i - 1);
        // Held, before the release: under symmetry the partner already follows, mirrored.
        if (sym && i + 1 == logs.length && grabV1 && g == 0) {
            size_t j;   // the grab's partner: v1's mirror image in `pts`
            foreach (k, a; pts) if (a[0] == -pts[1][0] && a[1] == pts[1][1]) j = k;
            const v = readVerticesLayer(1), p = v[1], q = v[j];
            assert(j > 1 && approxVec(Vec3(-p[0], p[1], p[2]), q, 1e-4),
                format("held: partner v%d %s must mirror the grab %s", j, q, p));
        }
        auto pr = postJson("/api/play-events", log);
        assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
        waitPlayerIdle();
        if (i + 1 == logs.length) { x0 += dx; y0 += dy; }
    }
    if (probe !is null && g == 0) probe(logs.length - 1);
    }
    cmd("tool.set mesh.topoPen off");
    cmd("tool.pipe.attr symmetry enabled false");
}

unittest { // KJP_A adjacent corners collapse; KJP_D diagonal corners weld to [0,2,1,2]
    sameQuadMove([[-0.5, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.36, 0.0], [-0.5, 0.36, 0.0]],
                 [0.0, 0.30, 0.0], 0, -30);
    assert(vertexCountLayer(1) == 3 && readFacesLayer(1) == [[0, 1, 2]],
        format("KJP_A: V=%d faces %s, expected 3 and [[0,1,2]]", vertexCountLayer(1),
               readFacesLayer(1)));
    sameQuadMove([[-0.3, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.36, 0.0], [-0.3, 0.36, 0.0]],
                 [-0.3, 0.30, 0.0], -30, -30);
    assert(vertexCountLayer(1) == 3 && readFacesLayer(1) == [[0, 2, 1, 2]],
        format("KJP_D: V=%d faces %s, expected 3 and [[0,2,1,2]]", vertexCountLayer(1),
               readFacesLayer(1)));
    postJson("/api/command", commandBody("scene.reset"));
}

// §5 — SYMMETRY (captured, KW2_A / KW2_B, task 9438): under world symmetry X the
// move drags the mirror partner too, and ONE weld pass over the moved set welds
// both: v1 into v4 and its partner v10 into v15 (16 - 2). Without symmetry only v1.
unittest { // KW2_A symmetric move welds both sides (14); KW2_B control (15)
    double[3][] pts = [[0.1, 0, 0], [0.3, 0, 0], [0.3, 0.3, 0], [0.1, 0.3, 0],
        [0.5, 0.06, 0], [1, 0.06, 0], [1, 0.36, 0], [0.5, 0.36, 0],
        [-0.1, 0.3, 0], [-0.3, 0.3, 0], [-0.3, 0, 0], [-0.1, 0, 0],
        [-0.5, 0.36, 0], [-1, 0.36, 0], [-1, 0.06, 0], [-0.5, 0.06, 0]];
    int[][] quads = [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15]];
    sameQuadMove(pts, [0.5, 0, 0], 20, 0, quads, false);
    assert(vertexCountLayer(1) == 15 && hasVertexNear(1, Vec3(-0.3f, 0, 0), 1e-4),
        format("KW2_B: V=%d, expected 15 with (-0.3,0) untouched", vertexCountLayer(1)));
    sameQuadMove(pts, [0.5, 0, 0], 20, 0, quads, true);
    assert(vertexCountLayer(1) == 14 && readFacesLayer(1)
        == [[0, 3, 1, 2], [3, 4, 5, 6], [7, 8, 13, 9], [10, 11, 12, 13]],
        format("KW2_A: V=%d faces %s, expected 14 and the mirror face [7,8,13,9]",
               vertexCountLayer(1), readFacesLayer(1)));
    assert(hasVertexNear(1, Vec3(-0.5f, 0.06f, 0), 1e-4) && !hasVertexNear(1, Vec3(-0.5f, 0, 0), 1e-3),
        "KW2_A: the mirror target keeps its position");
    // The same gesture from the -X side (its mirror image): the grab's side drives.
    double[3][] left = [[-0.3, 0.3, 0], [-0.3, 0, 0], [-0.1, 0, 0], [-0.1, 0.3, 0]];
    sameQuadMove(left ~ pts[12 .. 16] ~ pts[0 .. 8], [-0.5, 0, 0], -20, 0, quads, true);
    assert(vertexCountLayer(1) == 14 && hasVertexNear(1, Vec3(0.5f, 0.06f, 0), 1e-4)
        && !hasVertexNear(1, Vec3(0.3f, 0, 0), 1e-3) && !hasVertexNear(1, Vec3(-0.3f, 0, 0), 1e-3),
        format("KW2_A from -X: V=%d, expected 14", vertexCountLayer(1)));
    // A second gesture in the same session, after the weld: the pairing is re-taken.
    sameQuadMove(pts, [0.5, 0, 0], 20, 0, quads, true, null, null, 2);
    assert(vertexCountLayer(1) == 14 && hasVertexNear(1, Vec3(-0.705f, -0.005f, 0), 1e-3),
        format("KW2_A then a second grab: the partner follows: %s", readVerticesLayer(1)));
    // A hidden partner neither follows nor welds (the walker's hidden guard), though
    // an unpaired v16 sits 3 px from it: only the grab welds (17 - 1).
    double[3][] tri = [[-0.33, 0, 0], [-0.33, -0.2, 0], [-0.45, -0.2, 0]];
    sameQuadMove(pts ~ tri, [0.5, 0, 0], 20, 0,
                 quads ~ [[16, 17, 18]], true, pts[1].dup, [10]);
    assert(vertexCountLayer(1) == 18 && hasVertexNear(1, Vec3(-0.3f, 0, 0), 1e-4),
        format("KW2_A hidden partner: V=%d, expected 18 with v10 unmoved, unwelded", vertexCountLayer(1)));
    postJson("/api/command", commandBody("scene.reset"));
}

/// A K-W2b cell (symmetry X, task 9438): the fixture's rig, press and px drag; asserts
/// every position (6 mm: a vertex grab lands on its pixel's centre) and the faces.
void kw2b(string id, double[3][] pts, int[][] faces, double[2] press, int[2] drag,
          double[3][] pos, int[][] outFaces, int[2][] stops = null,
          void delegate(size_t) probe = null) {
    sameQuadMove(pts, [press[0] + drag[0] / 100.0, press[1] - drag[1] / 100.0, 0], drag[0], drag[1],
                 faces, true, press.dup, null, 1, stops, probe);
    const v = readVerticesLayer(1);
    bool same = v.length == pos.length && readFacesLayer(1) == outFaces;
    foreach (i, p; pos) same = same && approxVec(Vec3(p[0], p[1], p[2]), v[i], 6e-3);
    assert(same, format("%s: V=%d %s faces %s, expected %s %s", id, v.length, v,
                        readFacesLayer(1), pos, outFaces));
}

// §5b — K-W2b (captured): every element class writes its partners in CORNER order,
// last write wins (K, L, L4, L5; no partner: rigid, L2); an on-plane vertex is
// projected (N) but welds from the raw cursor (Nw); a grab and its own partner within
// reach fuse on the plane (M, M5), judged at their current positions (M4).
unittest { // K-W2b: K L L2 L4 L5 N Nw M M4 M5
    long[] rebuilds;   // §5c: the pair table across KW2_K's gesture
    kw2b("KW2_K", [[0.1, 0.0, 0.0], [0.4, 0.0, 0.0], [0.4, 0.4, 0.0], [0.1, 0.4, 0.0],
                   [-0.1, 0.4, 0.0], [-0.4, 0.4, 0.0], [-0.4, 0.0, 0.0], [-0.1, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]], [0.4, 0.2], [20, 0],
         [[0.1, 0.0, 0.0], [0.6, 0.0, 0.0], [0.6, 0.4, 0.0], [0.1, 0.4, 0.0],
          [-0.1, 0.4, 0.0], [-0.6, 0.4, 0.0], [-0.6, 0.0, 0.0], [-0.1, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]], null, (k) { rebuilds ~= pairingRebuilds(); });
    assert(rebuilds.length == 3, format("KW2_K rate: %d probes, expected 3", rebuilds.length));
    assert(rebuilds[1] == rebuilds[0] && rebuilds[2] == rebuilds[0] + 1, format(
        "KW2_K rate: pair-table rebuilds after the press / at the motion's end / after the "
      ~ "release %s: a drag step must not rebuild it (confined publish) and the release "
      ~ "must, once", rebuilds));
    kw2b("KW2_L", [[-0.2, 0.1, 0.0], [0.2, 0.1, 0.0], [0.2, 0.4, 0.0], [-0.2, 0.4, 0.0],
                   [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
                   [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], [0.05, 0.25], [20, 0],
         [[-0.4, 0.1, 0.0], [0.4, 0.1, 0.0], [0.0, 0.4, 0.0], [0.0, 0.4, 0.0],
          [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
          [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]]);
    kw2b("KW2_L2", [[-0.1, 0.1, 0.0], [0.3, 0.1, 0.0], [0.3, 0.4, 0.0], [-0.1, 0.4, 0.0],
                    [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
                    [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], [0.1, 0.25], [20, 0],
         [[0.1, 0.1, 0.0], [0.5, 0.1, 0.0], [0.5, 0.4, 0.0], [0.1, 0.4, 0.0],
          [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
          [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]]);
    kw2b("KW2_L4", [[-0.2, 0.1, 0.0], [0.2, 0.1, 0.0], [-0.2, 0.4, 0.0], [0.2, 0.4, 0.0],
                    [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
                    [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 3, 2], [4, 5, 6, 7], [8, 9, 10, 11]], [0.05, 0.25], [20, 0],
         [[-0.4, 0.1, 0.0], [0.4, 0.1, 0.0], [0.0, 0.4, 0.0], [0.0, 0.4, 0.0],
          [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
          [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[0, 1, 3, 2], [4, 5, 6, 7], [8, 9, 10, 11]]);
    kw2b("KW2_L5", [[-0.2, 0.1, 0.0], [0.2, 0.1, 0.0], [0.2, 0.4, 0.0], [-0.2, 0.4, 0.0],
                    [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
                    [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[3, 0, 1, 2], [4, 5, 6, 7], [8, 9, 10, 11]], [0.05, 0.25], [20, 0],
         [[-0.4, 0.1, 0.0], [0.4, 0.1, 0.0], [0.4, 0.4, 0.0], [-0.4, 0.4, 0.0],
          [0.8, 0.1, 0.0], [1.1, 0.1, 0.0], [1.1, 0.4, 0.0], [0.8, 0.4, 0.0],
          [-0.8, 0.4, 0.0], [-1.1, 0.4, 0.0], [-1.1, 0.1, 0.0], [-0.8, 0.1, 0.0]],
         [[3, 0, 1, 2], [4, 5, 6, 7], [8, 9, 10, 11]]);
    kw2b("KW2_N", [[0.0, 0.0, 0.0], [0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0],
                   [-0.9, 0.0, 0.0], [-0.9, 0.6, 0.0], [0.4, -0.36, 0.0], [0.7, -0.36, 0.0],
                   [0.7, -0.06, 0.0], [0.4, -0.06, 0.0], [-0.4, -0.06, 0.0], [-0.7, -0.06, 0.0],
                   [-0.7, -0.36, 0.0], [-0.4, -0.36, 0.0]],
         [[0, 1, 2, 3], [3, 5, 4, 0], [6, 7, 8, 9], [10, 11, 12, 13]], [0.0, 0.0], [20, -20],
         [[0.0, 0.2, 0.0], [0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0],
          [-0.9, 0.0, 0.0], [-0.9, 0.6, 0.0], [0.4, -0.36, 0.0], [0.7, -0.36, 0.0],
          [0.7, -0.06, 0.0], [0.4, -0.06, 0.0], [-0.4, -0.06, 0.0], [-0.7, -0.06, 0.0],
          [-0.7, -0.36, 0.0], [-0.4, -0.36, 0.0]],
         [[0, 1, 2, 3], [3, 5, 4, 0], [6, 7, 8, 9], [10, 11, 12, 13]]);
    kw2b("KW2_Nw", [[0.0, 0.0, 0.0], [0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0],
                    [-0.9, 0.0, 0.0], [-0.9, 0.6, 0.0], [0.4, -0.36, 0.0], [0.7, -0.36, 0.0],
                    [0.7, -0.06, 0.0], [0.4, -0.06, 0.0], [-0.4, -0.06, 0.0], [-0.7, -0.06, 0.0],
                    [-0.7, -0.36, 0.0], [-0.4, -0.36, 0.0]],
         [[0, 1, 2, 3], [3, 5, 4, 0], [6, 7, 8, 9], [10, 11, 12, 13]], [0.0, 0.0], [40, 0],
         [[0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0], [-0.9, 0.0, 0.0],
          [-0.9, 0.6, 0.0], [0.4, -0.36, 0.0], [0.7, -0.36, 0.0], [0.7, -0.06, 0.0],
          [0.4, -0.06, 0.0], [-0.4, -0.06, 0.0], [-0.7, -0.06, 0.0], [-0.7, -0.36, 0.0],
          [-0.4, -0.36, 0.0]],
         [[8, 0, 1, 2], [2, 4, 3, 8], [5, 6, 7, 8], [9, 10, 11, 12]]);
    kw2b("KW2_M", [[0.1, 0.0, 0.0], [0.4, 0.0, 0.0], [0.4, 0.4, 0.0], [0.1, 0.4, 0.0],
                   [-0.1, 0.4, 0.0], [-0.4, 0.4, 0.0], [-0.4, 0.0, 0.0], [-0.1, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]], [0.1, 0.0], [-20, 0],
         [[0.0, 0.0, 0.0], [0.4, 0.0, 0.0], [0.4, 0.4, 0.0], [0.1, 0.4, 0.0],
          [-0.1, 0.4, 0.0], [-0.4, 0.4, 0.0], [-0.4, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 0]]);
    kw2b("KW2_M4", [[0.3, 0.0, 0.0], [0.6, 0.0, 0.0], [0.6, 0.4, 0.0], [0.3, 0.4, 0.0],
                    [-0.3, 0.4, 0.0], [-0.6, 0.4, 0.0], [-0.6, 0.0, 0.0], [-0.3, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]], [0.3, 0.0], [-60, 0],
         [[-0.3, 0.0, 0.0], [0.6, 0.0, 0.0], [0.6, 0.4, 0.0], [0.3, 0.4, 0.0],
          [-0.3, 0.4, 0.0], [-0.6, 0.4, 0.0], [-0.6, 0.0, 0.0], [0.3, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]]);
    kw2b("KW2_M5", [[0.3, 0.0, 0.0], [0.6, 0.0, 0.0], [0.6, 0.4, 0.0], [0.3, 0.4, 0.0],
                    [-0.3, 0.4, 0.0], [-0.6, 0.4, 0.0], [-0.6, 0.0, 0.0], [-0.3, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 7]], [0.3, 0.0], [-30, 0],
         [[0.0, 0.0, 0.0], [0.6, 0.0, 0.0], [0.6, 0.4, 0.0], [0.3, 0.4, 0.0],
          [-0.3, 0.4, 0.0], [-0.6, 0.4, 0.0], [-0.6, 0.0, 0.0]],
         [[0, 1, 2, 3], [4, 5, 6, 0]]);
    postJson("/api/command", commandBody("scene.reset"));
}

// §5c — the live move under symmetry (tasks 9493, 9495). A drag step publishes
// CONFINED, so the pair table built before the press serves the whole drag and the
// release's one unconfined publish rebuilds it once (KW2_K's gesture in §5b, 16 steps).
// An on-plane vertex snaps from its RAW position mid-drag and is projected only when
// nothing answers (KW2_Nw2: steps 3 and 5 on x = 0, steps 8 and 10 on (0.4,-0.26)).
long pairingRebuilds() {
    quiesce();
    getJson("/api/toolpipe/eval");
    quiesce();
    return getJson("/api/cache/rebuilds")["symmetryPairingRebuilds"].integer;
}

unittest { // KW2_Nw2: the live raw snap of an on-plane vertex
    double[3][] seen;
    size_t[] counts;
    kw2b("KW2_Nw2", [[0.0, 0.0, 0.0], [0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0],
                     [-0.9, 0.0, 0.0], [-0.9, 0.6, 0.0], [0.4, -0.56, 0.0], [0.7, -0.56, 0.0],
                     [0.7, -0.26, 0.0], [0.4, -0.26, 0.0], [-0.4, -0.26, 0.0], [-0.7, -0.26, 0.0],
                     [-0.7, -0.56, 0.0], [-0.4, -0.56, 0.0]],
         [[0, 1, 2, 3], [3, 5, 4, 0], [6, 7, 8, 9], [10, 11, 12, 13]], [0.0, 0.0], [40, 20],
         [[0.9, 0.0, 0.0], [0.9, 0.6, 0.0], [0.0, 0.6, 0.0], [-0.9, 0.0, 0.0],
          [-0.9, 0.6, 0.0], [0.4, -0.56, 0.0], [0.7, -0.56, 0.0], [0.7, -0.26, 0.0],
          [0.4, -0.26, 0.0], [-0.4, -0.26, 0.0], [-0.7, -0.26, 0.0], [-0.7, -0.56, 0.0],
          [-0.4, -0.56, 0.0]],
         [[8, 0, 1, 2], [2, 4, 3, 8], [5, 6, 7, 8], [9, 10, 11, 12]],
         [[12, 6], [20, 10], [32, 16]], (k) {
             const v = readVerticesLayer(1);
             counts ~= v.length;
             seen ~= v[0];
         });
    assert(counts.length == 6 && counts[0 .. 5] == [14, 14, 14, 14, 14],
        format("KW2_Nw2: %d probes, vertex counts %s: nothing welds before the release",
               counts.length, counts));
    foreach (k, want; [[0.0, -0.06], [0.0, -0.1], [0.4, -0.26], [0.4, -0.26]])
        assert(abs(seen[k + 1][0] - want[0]) <= 1e-6
            && abs(seen[k + 1][1] - want[1]) <= (want[0] == 0 ? 6e-3 : 1e-6), format(
            "KW2_Nw2 step %d: the on-plane vertex is at %s, expected %s (%s)", [3, 5, 8, 10][k],
            seen[k + 1], want, want[0] == 0 ? "projected onto x = 0: nothing in reach"
                                            : "snapped onto the in-reach target"));

    // The live snap reads CURRENT positions: an edge (0,0)-(0.3,0.2) moved by
    // (-0.3,+0.2) carries the on-plane v0's raw target onto where v1's partner v5
    // STARTED (-0.3,0.2), while v5 itself follows v1 to (0,0.4). Nothing is there
    // now, so v0 is projected to (0,0.2); a grid held from before the drag that did
    // not exclude the partners would snap it onto v5.
    double[3] held;
    sameQuadMove([[0.0, 0.0, 0.0], [0.3, 0.2, 0.0], [0.3, 0.8, 0.0], [0.0, 0.8, 0.0],
                  [-0.3, 0.8, 0.0], [-0.3, 0.2, 0.0]], [-0.15, 0.3, 0.0], -30, -20,
                 [[0, 1, 2, 3], [3, 4, 5, 0]], true, [0.15, 0.1], null, 1, null, (k) {
                     if (k == 1) held = readVerticesLayer(1)[0];
                 });
    assert(abs(held[0]) <= 1e-6 && abs(held[1] - 0.2) <= 6e-3, format(
        "a held on-plane v0 is at %s, expected (0,0.2): projected, not snapped onto the "
      ~ "partner's pre-drag position", held));
    postJson("/api/command", commandBody("scene.reset"));
}
