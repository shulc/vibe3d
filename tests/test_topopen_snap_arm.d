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

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : sqrt, abs;
import std.format : format;

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

    auto u = postJson("/api/undo", "");
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
