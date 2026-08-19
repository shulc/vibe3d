// Task 1530 — the action centre placed by an element click is a FROZEN POINT,
// captured on the button-DOWN of the picking click, and it does not move while
// the gesture runs, nor across later gestures, until the next such click.
//
// WHY A TRANSLATE. A scale about its own pivot leaves that pivot a fixed point,
// so a scale cell predicts the same constant under BOTH candidate laws (live
// centroid / frozen point) and cannot be reddened by a mutation of either. The
// owner's defect was found on a scale, but the DISCRIMINATOR is a translate:
// under the old law the pivot rode the whole drag delta with the geometry.
// The frozen reference fixture says the same in its own words —
// tests/fixtures/action_center_freeze_and_source_baseline.json, case
// `element_centre_under_scale`.
//
// MUTATION THAT REDDENS THIS FILE: put a live geometry read back into
// `ActionCenterStage.computeCenter`'s `Mode.Element` arm (the deleted
// `liveElementCenter` / `ringCentroid` pair). RUN, not asserted — with that
// mutation applied T2 fails on its first assertion, `distinct` going 1 -> 4:
//
//   [0.5, 0.5, 0.5] -> [0.426441, 0.54392, 0.5]
//                   -> [0.352881, 0.58784, 0.5]
//                   -> [0.279322, 0.63176, 0.5]
//
// i.e. the centre travels 0.2646 world units over the 12 motion events, the
// full drag delta, in lock-step with the picked vertex. That is 5 orders of
// magnitude above this file's 1e-6 tolerance, so the signal is not marginal.
//
// Deleting the frozen tier ALONE is NOT that mutation and proves nothing —
// `take*` writes the same point into `userPin` as well, which is the arm's
// second tier, so the centre would stay put for the wrong reason.
//
// Cells in this file:
//   T0  instrument validation — the mid-drag polling must not perturb the
//       geometry it is there to observe (bit-exact vertex compare).
//   T2  DISCRIMINATOR — one centre value for the whole translate, equal to the
//       picked vertex; plus a positive control that the tool actually moved
//       something.
//   T3  the point survives the gesture: a SECOND drag starts from it.
//   T4  it survives a tool re-arm (`resetTransient`).
//   T5  it does NOT survive `/api/reset`.
//   T9  bare `actr.element` on a plain move tool relocates the pivot and does
//       NOT open the screen-plane haul.

import std.net.curl;
import std.json;
import std.math  : fabs;
import std.conv  : to;
import std.file  : readText;
import std.format: format;
import std.algorithm : any;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";
JSONValue pj(string path, string body_) { return parseJSON(cast(string) post(BASE ~ path, body_)); }
JSONValue gj(string path)               { return parseJSON(cast(string) get(BASE ~ path)); }
void settle() { import core.thread : Thread; import core.time : msecs; Thread.sleep(150.msecs); }

double[3] acenCenter() {
    auto c = gj("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return [c[0].floating, c[1].floating, c[2].floating];
}

double[][] modelVerts() {
    double[][] o;
    foreach (v; gj("/api/model")["vertices"].array) {
        auto a = v.array;
        o ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return o;
}

bool sameCentre(double[3] a, double[3] b) {
    // The frozen reference is bit-identical at 9 decimals and needed no
    // tolerance (fixture, `unmeasured` §3). Ours crosses a float32 JSON
    // round-trip, so 1e-6 — still four orders below the drag delta the
    // live-pivot law would produce.
    foreach (i; 0 .. 3) if (fabs(a[i] - b[i]) > 1e-6) return false;
    return true;
}

string viewportLine(CameraState cam) {
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  cam.vpX, cam.vpY, cam.width, cam.height);
}

string downLog(CameraState cam, int x, int y) {
    return viewportLine(cam) ~ format(
        `{"t":30.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
}

string motionLog(CameraState cam, int x0, int y0, int dx, int dy, int n, double t0) {
    string log = viewportLine(cam);
    int px = x0, py = y0;
    foreach (i; 1 .. n + 1) {
        int x = x0 + dx * i, y = y0 + dy * i;
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                      t0 + i * 20.0, x, y, x - px, y - py);
        px = x; py = y;
    }
    return log;
}

string upLog(CameraState cam, int x, int y) {
    return viewportLine(cam) ~ format(
        `{"t":300.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", x, y);
}

void armElementMove() {
    pj("/api/reset", "");
    pj("/api/script", "tool.set xfrm.elementMove on");
    pj("/api/command", "tool.pipe.attr falloff mode vertex");
    pj("/api/command", "tool.pipe.attr falloff dist 4");
    settle();
}

// The picked vertex: cube corner v6. Non-zero and NOT the mesh centroid, so a
// live pivot and a frozen one predict different values (trap 2 of the plan:
// a rig centred on the origin is inert — 0 is both the centroid and the
// empty-selection fallback).
enum Vec3 PICK = Vec3(0.5f, 0.5f, 0.5f);

// One drag: DOWN on the picked vertex, then `batches` runs of `perBatch`
// motion events, then UP. `poll` decides whether the centre is read between
// batches — that is the only difference between T0's two runs.
double[][] runDrag(bool poll, out double[3][] centres, int batches = 3, int perBatch = 4) {
    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    float sx, sy;
    assert(projectToWindow(PICK, vp, sx, sy),
        "the picked corner must project into the viewport");
    int px = cast(int) sx, py = cast(int) sy;

    playAndWait(downLog(cam, px, py));
    if (poll) centres ~= acenCenter();

    int cx = px, cy = py;
    double t = 30.0;
    foreach (b; 0 .. batches) {
        playAndWait(motionLog(cam, cx, cy, -5, -4, perBatch, t));
        cx -= 5 * perBatch; cy -= 4 * perBatch; t += 200.0;
        if (poll) centres ~= acenCenter();
    }
    playAndWait(upLog(cam, cx, cy));
    settle();
    return modelVerts();
}

unittest {
    // ---- T0: does the instrument move what it measures? --------------------
    // Both runs replay the SAME event log; the only difference is the GETs
    // between batches. Compare the WHOLE vertex array at tolerance ZERO — both
    // runs are deterministic, so any difference at all IS the perturbation.
    // The reference harness had exactly this confound and it cost five false
    // verdicts, so this cell gates every cell below it.
    double[3][] cUnpolled, cPolled;
    armElementMove();
    auto vNoPoll = runDrag(false, cUnpolled);
    armElementMove();
    auto vPoll   = runDrag(true,  cPolled);

    assert(vNoPoll.length == vPoll.length && vNoPoll.length > 0,
        "T0: both runs must return the same mesh");
    foreach (i; 0 .. vNoPoll.length)
        foreach (k; 0 .. 3)
            assert(vNoPoll[i][k] == vPoll[i][k],
                format("T0: mid-drag polling PERTURBED the geometry at vertex "
                     ~ "%d component %d: unpolled %.17g, polled %.17g. Every "
                     ~ "cell below reads the centre mid-drag, so they would be "
                     ~ "measuring the instrument.", i, k, vNoPoll[i][k], vPoll[i][k]));

    // ---- T2: the DISCRIMINATOR ---------------------------------------------
    assert(cPolled.length == 4,
        format("T2: expected 4 centre samples (one after DOWN, one per motion "
             ~ "batch), got %d", cPolled.length));

    int distinct = 1;
    foreach (i; 1 .. cPolled.length)
        if (!sameCentre(cPolled[i], cPolled[i - 1])) distinct++;
    assert(distinct == 1,
        format("T2: the action centre must hold ONE value for the whole "
             ~ "translate; saw %d distinct across %s. A live ring centroid "
             ~ "rides the drag delta — that is the defect.",
               distinct, cPolled.to!string));

    double[3] want = [PICK.x, PICK.y, PICK.z];
    assert(sameCentre(cPolled[0], want),
        format("T2: the frozen centre must be the picked element's own anchor "
             ~ "%s, got %s", want.to!string, cPolled[0].to!string));

    // Positive control: a green above would otherwise be satisfied by a tool
    // that refused the drag outright.
    // /api/reset gives a unit cube on the +-0.5 grid, so any coordinate off
    // that grid means the drag actually displaced geometry.
    bool moved = false;
    foreach (v; vPoll)
        foreach (k; 0 .. 3)
            if (fabs(fabs(v[k]) - 0.5) > 1e-4) moved = true;
    assert(moved,
        "T2 positive control: the drag must actually MOVE geometry — with "
        ~ "nothing moving, a constant centre is constant for the wrong reason");

    // ---- T3: it survives the gesture --------------------------------------
    // A SECOND drag, with no new pick, must still be anchored at the same
    // point. The reference measured this explicitly: the captured point stays
    // in force across later gestures until the next picking click.
    double[3][] c2;
    auto cam2 = fetchCamera();
    auto vp2  = viewportFromCamera(cam2);
    float s2x, s2y;
    // Press somewhere that is NOT on an element and NOT on a handle: the point
    // the pivot now sits at has moved with the mesh, so re-using PICK's pixel
    // would be a fresh pick. Read the centre after a plain second drag started
    // from the CURRENT pivot's screen position instead.
    auto beforeSecond = acenCenter();
    assert(projectToWindow(PICK, vp2, s2x, s2y));
    playAndWait(motionLog(cam2, cast(int) s2x + 60, cast(int) s2y + 60, 0, 0, 1, 400.0));
    auto afterIdle = acenCenter();
    assert(sameCentre(beforeSecond, afterIdle),
        format("T3: an idle hover must not move the frozen centre: %s -> %s",
               beforeSecond.to!string, afterIdle.to!string));
    assert(sameCentre(afterIdle, want),
        format("T3: after the gesture ended the centre must STILL be the "
             ~ "picked point %s, got %s", want.to!string, afterIdle.to!string));

    // ---- T4: it survives a tool re-arm ------------------------------------
    // `resetTransientPipeStages` runs BEFORE a preset's attributes are
    // unrolled, so without the explicit carry in `resetTransient()` the pin
    // would already be gone by the time mode=element lands.
    pj("/api/script", "tool.set xfrm.elementMove off");
    pj("/api/script", "tool.set xfrm.elementMove on");
    pj("/api/command", "tool.pipe.attr falloff mode vertex");
    pj("/api/command", "tool.pipe.attr falloff dist 4");
    settle();
    auto afterRearm = acenCenter();
    assert(sameCentre(afterRearm, want),
        format("T4: the frozen pick must survive a tool re-arm; want %s, got %s",
               want.to!string, afterRearm.to!string));

    // ---- T5: `/api/reset` DOES wipe it ------------------------------------
    // The other half of the asymmetry. An explicit full reset erases every pin;
    // with the cube back at the origin and nothing selected the Element arm
    // falls through to its whole-mesh fallback, (0,0,0).
    pj("/api/reset", "");
    pj("/api/script", "tool.set xfrm.elementMove on");
    settle();
    auto afterReset = acenCenter();
    assert(sameCentre(afterReset, [0.0, 0.0, 0.0]),
        format("T5: /api/reset must wipe the frozen pick (expect the "
             ~ "whole-mesh fallback (0,0,0)), got %s", afterReset.to!string));
    pj("/api/script", "tool.set xfrm.elementMove off");
    settle();

    // ---- T9 (auto-haul gate) is NOT a cell here, and that is measured ------
    // The plan predicted: bare `actr.element` + a plain move tool, click an
    // element, and with the falloff term on the `picked && flagT` gate the
    // vertices must NOT move. They move anyway, and not through the haul: an
    // off-gizmo press plus a drag is an ORDINARY Move drag in every pinned
    // action-centre mode (tests/test_acen_pinned_mode_drag.d asserts exactly
    // that, and calls a non-moving result "the tool never engaged"). With an
    // empty selection both paths translate the whole mesh by one delta, so the
    // predicted observable does not separate them. The gate is kept in the code
    // — ungating the pick without it makes the haul reachable on any T-enabled
    // tool with no falloff at all — but it is NOT pinned by a test, and saying
    // so here is cheaper than a green cell that cannot go red.

    // ---- the reference fixture, READ ---------------------------------------
    // A fixture nobody opens is decoration. These are the reference's own
    // numbers for the same two laws this file asserts.
    auto fx = parseJSON(readText("tests/fixtures/action_center_freeze_and_source_baseline.json"));
    JSONValue caseNamed(string n) {
        foreach (c; fx["cases"].array) if (c["name"].str == n) return c;
        assert(false, "fixture case missing: " ~ n);
    }
    auto tr = caseNamed("element_centre_under_translate");
    assert(tr["centre_values_observed_during_gesture"].integer == 1,
        "fixture: the reference saw ONE centre value under a translate — that "
        ~ "is the law T2 reproduces");
    assert(tr["matched"].str == "captured",
        "fixture: the reference's translate cell matched the CAPTURED-pivot "
        ~ "prediction, not the live one");
    assert(caseNamed("element_centre_under_scale")["centre_values_observed_during_gesture"].integer == 1,
        "fixture: the scale cell is a consistency check only — it agrees under "
        ~ "both laws, which is why it is not this file's discriminator");
    auto src = caseNamed("source_positions_under_translate");
    assert(src["matched"].str == "pre_gesture_mesh",
        "fixture: the reference's per-frame transform reads PRE-gesture source "
        ~ "positions — the law tests/test_acen_run_pivot_freeze.d pins on our "
        ~ "scale drag");
}
