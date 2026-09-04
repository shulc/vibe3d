// Action centre: the relocate pin has a WRITE gate and a READ gate, and they
// are not the same predicate (task 0712).
//
// "May a click off the gizmo relocate the action centre?" is answered THREE
// times in the tree — task 0712 filed it as two, and the third is why the
// first cannot be flipped on its own:
//
//   `ActionCenterStage.honoursPlacedCenter(mode)`  (source/toolpipe/stages/actcenter.d)
//       the READ gate. "A user pin exists. Does this mode honour it over its
//       own centre?"  Pivot/Parent: YES, deliberately, task 0187 — "an
//       explicit relocation to a chosen point is defensible even for the live
//       item pivot".
//
//   `TransformTool.pressPlacesCenter()`  (source/tools/transform/transform.d)
//       the WRITE gate. "Does a plain off-gizmo press in this mode PLACE such
//       a pin?"  Pivot/Parent: NO.
//
//   `TransformTool.computeClickRelocateHitRaw()` (same file, ~260 lines below)
//       the PLANE gate. "Is there a surface in this mode to project the click
//       ray onto at all?"  Pivot/Parent: NO — its own `final switch` puts them
//       in the `return false` arm with Select/Local/Origin/Manual/Border. This
//       is the switch task 0712's evidence notes the Pivot/Parent commit was
//       FORCED to classify them in, because it is exhaustive.
//
// The two write-side gates refuse INDEPENDENTLY, and that is measured, not
// read: flipping `pressPlacesCenter` alone leaves every assertion in
// this file green, because the press then reaches `computeClickRelocateHit`,
// gets no plane, and the bank refuses it anyway. Only opening BOTH moves the
// centre — at which point the `pivot` case below fails with
// "userPlaced=true, centre (0,0,0) -> (-1.7268, 0.9997, 0)".
//
// So "unify onto the deliberate one" is not one edit to one predicate. It is a
// design decision about which plane a Pivot-mode click would even project
// onto, plus a second edit to a predicate that is separately load-bearing for
// something else (see below). What this file guards is the OBSERVABLE — where
// the published centre ends up — which is the conjunction of all three.
//
// This file does not decide which is right. It makes the split OBSERVABLE, so
// that whichever way it is eventually settled, the settling is a visible
// change to a table rather than an invisible change to one of two spellings —
// which is how the divergence arose in the first place.
//
// The three modes below are chosen because they separate the two gates
// completely. Read the table down the "pin honoured" column:
//
//   mode     off-gizmo click places a pin?   a pin, once placed, is honoured?
//   ------   ----------------------------    -------------------------------
//   auto              YES                              YES
//   pivot             NO                               YES     <-- the split
//   origin            NO                               NO
//
// `origin` is the control that makes `pivot` mean something: it is the mode
// where BOTH gates refuse, so the pin is accepted by the stage's attr and the
// published centre still does not move. Without it, "the click did not
// relocate under pivot" would be indistinguishable from "the pin machinery is
// simply off in every non-auto mode".
//
// Why the split is reachable rather than academic: the write gate is not the
// only route to a pin. `TransformTool.notifyAcenUserPlaced` has no mode gate
// of its own, and the falloff element-pick path (`XfrmTransformTool
// .tryPickElement` -> takeVert/takeEdge/takeFace) calls it whenever the
// falloff type is Element, whatever the action-centre mode is. So under
// `actr.pivot` a pin CAN be placed by a click on an element and IS then
// honoured — while the plain off-gizmo click, the gesture that is nominally
// THE relocate, refuses. The stage attr driven below is the deterministic
// stand-in for that write (the same seam tests/test_acen_auto_relocate.d
// uses, and the same one `setUserPlaced` sits behind).
//
// Both of today's answers are load-bearing, so neither may be "unified" away
// without a decision:
//   - the READ side allowing Pivot/Parent is pinned by an in-module
//     characterization unittest in actcenter.d (task 0187 mutation-tested it
//     with a "Pivot relocate revert").
//   - the WRITE side refusing Pivot/Parent is pinned by
//     tests/test_item_panel_gizmo_sync.d, whose `actr.pivot` case exists
//     BECAUSE the mode is relocate-disallowed: flipping this predicate to
//     true makes the Item-mode off-gizmo guard swallow the press, and that
//     test fails with "an off-gizmo drag in a relocate-DISALLOWED mode
//     (`actr.pivot`) must still move the item". Measured, not inferred.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias BASE = testBaseUrl;


void cmd(string argstring) {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/command", argstring));
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto j = parseJSON(cast(string) post(BASE ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

// The ACEN stage's own published attributes — `mode` and `userPlaced`.
string[string] acenAttrs() {
    foreach (st; getJson("/api/toolpipe")["stages"].array)
        if (st["task"].str == "ACEN") {
            string[string] m;
            foreach (k, v; st["attrs"].object) m[k] = v.str;
            return m;
        }
    assert(false, "ACEN stage not found in /api/toolpipe");
}

// The authoritative published pivot — what the gizmo and every transform
// linearise about. Read from the pipe EVAL, not from a tool's own copy.
struct P3 { double x, y, z; }

P3 centre() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return P3(a[0].floating, a[1].floating, a[2].floating);
}

string show(P3 p) { return format("(%.4f, %.4f, %.4f)", p.x, p.y, p.z); }

bool near(P3 a, P3 b, double eps = 1e-3) {
    return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps;
}

void waitPlayback() {
    foreach (_; 0 .. 300) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) {
            Thread.sleep(150.msecs);   // let the frame that consumed it settle
            return;
        }
        Thread.sleep(20.msecs);
    }
    assert(false, "play-events did not finish within 6 s");
}

// One bare down+up at a pixel, no motion between — a click, not a drag.
void clickAt(int x, int y) {
    auto c = getJson("/api/camera");
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n"
      ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
      ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cast(int) c["vpX"].integer, cast(int) c["vpY"].integer,
        cast(int) c["width"].integer, cast(int) c["height"].integer,
        x, y, x, y);
    auto r = parseJSON(cast(string) post(BASE ~ "/api/play-events", log));
    assert(r["status"].str == "success", "/api/play-events failed: " ~ r.toString);
    waitPlayback();
}

// A corner pixel: no gizmo handle and no geometry under it — the definition of
// "the click missed the gizmo".
void clickOffGizmo() {
    auto c = getJson("/api/camera");
    clickAt(cast(int) c["vpX"].integer + 30, cast(int) c["vpY"].integer + 30);
}

// Write a pin straight into the stage, bypassing the tool-side write gate
// entirely. This is the deterministic stand-in for every non-click route to
// `setUserPlaced` — chiefly the falloff element pick.
enum P3 PIN = P3(2.0, 1.0, -1.0);

void writePinDirectly() {
    cmd(format("tool.pipe.attr actionCenter userPlacedX %s", PIN.x));
    cmd(format("tool.pipe.attr actionCenter userPlacedY %s", PIN.y));
    cmd(format("tool.pipe.attr actionCenter userPlacedZ %s", PIN.z));
}

// ---------------------------------------------------------------------------
// One mode, both gates, measured in order: baseline -> click -> direct pin.
// ---------------------------------------------------------------------------
struct GateReading {
    P3   baseline;
    bool clickPlacedPin;
    P3   afterClick;
    bool pinAccepted;
    P3   afterPin;
}

GateReading readGates(string modePreset) {
    resetCube();
    cmd(modePreset);
    cmd("tool.set move");
    scope(exit) cmd("tool.set move off");

    GateReading g;
    g.baseline = centre();
    assert(acenAttrs()["userPlaced"] == "false",
        modePreset ~ ": precondition — a fresh stage must carry no pin, else "
        ~ "every reading below is about a leftover from another case");

    clickOffGizmo();
    g.clickPlacedPin = acenAttrs()["userPlaced"] == "true";
    g.afterClick     = centre();

    writePinDirectly();
    g.pinAccepted = acenAttrs()["userPlaced"] == "true";
    g.afterPin    = centre();
    return g;
}

// ---------------------------------------------------------------------------
// 1. `auto` — both gates open. The reference row.
// ---------------------------------------------------------------------------
unittest {
    auto g = readGates("actr.auto");

    assert(g.clickPlacedPin,
        "actr.auto: an off-gizmo click must place a user pin — this is the "
        ~ "row that proves the click machinery in this file works at all, so "
        ~ "a refusal measured under `pivot` below is a decision and not a "
        ~ "broken click");
    assert(!near(g.afterClick, g.baseline),
        "actr.auto: the published centre must MOVE with the click, from "
        ~ show(g.baseline) ~ "; it stayed at " ~ show(g.afterClick));
    assert(near(g.afterPin, PIN),
        "actr.auto: a directly written pin must be honoured; centre is "
        ~ show(g.afterPin) ~ ", pin is " ~ show(PIN));
}

// ---------------------------------------------------------------------------
// 2. `origin` — both gates shut. The control that gives row 3 its meaning.
// ---------------------------------------------------------------------------
unittest {
    auto g = readGates("actr.origin");

    assert(!g.clickPlacedPin && near(g.afterClick, g.baseline),
        "actr.origin: an off-gizmo click must not relocate a fixed-point "
        ~ "centre. userPlaced=" ~ g.clickPlacedPin.to!string
        ~ ", centre " ~ show(g.baseline) ~ " -> " ~ show(g.afterClick));
    assert(g.pinAccepted,
        "actr.origin: precondition — the stage still ACCEPTS the pin write "
        ~ "(userPlaced flips true); what follows is about whether it is READ");
    assert(near(g.afterPin, g.baseline),
        "actr.origin: a pin is written but must be IGNORED — the centre stays "
        ~ "the world origin. This is the discriminating control: it is what "
        ~ "'both gates refuse' looks like, and without it the `pivot` case "
        ~ "below could be read as the pin machinery simply being off outside "
        ~ "auto. Centre moved to " ~ show(g.afterPin));
}

// ---------------------------------------------------------------------------
// 3. `pivot` — THE SPLIT. Write gate shut, read gate open.
// ---------------------------------------------------------------------------
unittest {
    auto g = readGates("actr.pivot");

    // WRITE side: refuses. Pinned independently, and for its own reason, by
    // tests/test_item_panel_gizmo_sync.d — flipping it opens the Item-mode
    // off-gizmo guard and turns a legitimate item drag into a no-op.
    assert(!g.clickPlacedPin && near(g.afterClick, g.baseline),
        "actr.pivot: an off-gizmo click must NOT place a pin — "
        ~ "`pressPlacesCenter()` refuses this mode, and the Item-mode "
        ~ "off-gizmo drag depends on that refusal. userPlaced="
        ~ g.clickPlacedPin.to!string ~ ", centre " ~ show(g.baseline)
        ~ " -> " ~ show(g.afterClick));

    // READ side: honours. Deliberate, task 0187.
    assert(near(g.afterPin, PIN),
        "actr.pivot: a pin placed by any route OTHER than the click must be "
        ~ "honoured over the live item pivot — `honoursPlacedCenter` includes "
        ~ "Pivot on purpose (task 0187). Centre is " ~ show(g.afterPin)
        ~ ", pin is " ~ show(PIN) ~ ". If this now fails, the read side was "
        ~ "narrowed: that is option (B) of task 0712 and revokes 0187, so it "
        ~ "must be a decision, not a side effect.");

    // And the two together ARE the divergence, stated as one assertion so the
    // next reader meets it as a fact rather than as prose in a comment.
    assert(!g.clickPlacedPin && near(g.afterPin, PIN),
        "actr.pivot is the mode where the two spellings of 'may a click "
        ~ "relocate the action centre' disagree: the WRITE gate "
        ~ "(`pressPlacesCenter`) refuses, the READ gate "
        ~ "(`ActionCenterStage.honoursPlacedCenter`) honours. Compare with "
        ~ "`auto` (both open) and `origin` (both shut) above. Task 0712 is "
        ~ "the decision about whether that stays; this assertion exists so "
        ~ "the decision cannot be made by accident.");
}
