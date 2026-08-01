// The click-relocate plane point is quantised to TEN GRID STEPS (task 0570).
//
// The law: relocating the action centre by clicking away from the gizmo puts
// the pivot on the principal plane through the camera focus — but the focus's
// OUT-OF-PLANE coordinate is first rounded to a multiple of `10 * gridSize`,
// and the grid step is itself the world length of 25 screen pixels rounded up
// onto a mantissa ladder. So the quantum follows the zoom.
//
// The rounding shipped implemented, tested and DORMANT (the port defaulted
// `RelocatePlanePrefs.quantumStep` to 0) because the step it rounds to was
// unknown, and two capture rigs appeared to demand incompatible constants.
// That turned out to be an axis-index mistake, and with the step derived from
// zoom rather than fixed both rigs reproduce exactly. This file is the
// product-level half: it asserts the quantum is LIVE, that it is the grid's,
// and that it follows the camera.
//
// WHY THE FOCUS HAS TO BE MOVED, and why nothing already in the tree covers
// this: the origin is a fixed point of `round(x/q)*q` for every q, so a rig
// whose camera focus sits at the world origin cannot see this term at all.
// Every one of the 87 cached rows in the cross-engine drag corpus has
// `camera.center == [0,0,0]`. A green corpus is therefore a regression check
// here and not evidence, which is exactly why this file exists.
//
// The discriminator, on a camera looking mostly straight down (so the
// principal axis is Y):
//   * quantum DORMANT — the pivot's Y is the raw focus Y (0.34, 1.40);
//   * quantum LIVE    — it is that rounded to a multiple of 10*gridSize
//                       (0.0 and 2.0 at a step of 0.2).
// The two answers differ by more than half a world unit, so no tolerance
// question arises.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : abs, floor, ceil;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void settle() { Thread.sleep(200.msecs); }

string[string] getAcenAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "ACEN") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "ACEN stage not found in /api/toolpipe payload");
}

float floatAttr(string[string] attrs, string key) { return attrs[key].to!float; }

/// A JSON number whatever kind std.json decided it was. The endpoint prints
/// the step with `%.9g` — which a step of exactly 1 renders as "1", i.e. an
/// INTEGER — so `.floating` alone throws on precisely the roundest values.
double jsonNum(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        default: throw new Exception("not a number: " ~ v.toString);
    }
}

/// The active cell's grid step, as the renderer computes it.
double gridStep() {
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"];
    return jsonNum(g["size"]);
}

/// Round half AWAY from zero — the law's rounding, restated here rather than
/// imported so the test is not checking the product against itself.
double dnint(double x) { return x >= 0 ? floor(x + 0.5) : ceil(x - 0.5); }

/// Cube + Move tool + Auto action centre + a camera looking mostly straight
/// down from `dist` at a focus of (0, fy, 0).
///
/// The elevation is high on purpose: the quantum applies to the camera's
/// PRINCIPAL axis, and only a near-top view makes that axis Y — which is the
/// axis the focus is displaced along. A three-quarter view would quantise X
/// or Z instead and this file would be asserting about a coordinate it never
/// moved. (Not hypothetical: reading the wrong axis under a rig is what left
/// this term dormant for two rounds.)
void setup(float fy, float dist) {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/script",  "tool.set move");
    postJson("/api/command", "tool.pipe.attr actionCenter mode auto");
    postJson("/api/camera", format(
        `{"azimuth":0.0,"elevation":1.35,"distance":%.6f,`
        ~ `"focus":{"x":0.0,"y":%.6f,"z":0.0}}`, dist, fy));
    settle();
}

/// A zero-motion left-click clear of every gizmo handle.
void clickOffGizmo() {
    auto cam = fetchCamera();
    int cx = cam.vpX + cam.width  / 2;
    int cy = cam.vpY + cam.height / 2;
    int x  = cx - cam.width  / 4;
    int y  = cy - cam.height / 4;
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x, y, x, y, 1));
    settle();
}

// -------------------------------------------------------------------------
// 1. The quantum is LIVE, and it is ten grid steps.
//
// Two foci on either side of a rounding boundary, so neither row can pass by
// the quantum happening to be the identity.
// -------------------------------------------------------------------------
unittest {
    struct Row { float focusY; }
    foreach (r; [Row(0.34f), Row(1.40f), Row(3.10f)]) {
        setup(r.focusY, 3.86f);

        immutable double step = gridStep();
        immutable double q    = 10.0 * step;
        assert(q > 0, "the grid step must be positive for the quantum to exist");

        clickOffGizmo();
        auto a = getAcenAttrs();
        assert(a["userPlaced"] == "true",
            "the click-away must relocate; got userPlaced=" ~ a["userPlaced"]);

        immutable double want = dnint(cast(double)r.focusY / q) * q;
        immutable double got  = floatAttr(a, "cenY");
        assert(abs(got - want) < 1e-3,
            format("focus y=%.4f at step %.4f (quantum %.4f): the pivot's Y "
                   ~ "must be the focus ROUNDED to %.4f, got %.6f",
                   r.focusY, step, q, want, got));
        // ...and it is not simply the raw focus. Without this the row above
        // passes whenever the rounding happens to be the identity.
        if (abs(cast(double)r.focusY - want) > 1e-3)
            assert(abs(got - r.focusY) > 1e-2,
                format("focus y=%.4f: the pivot's Y is the RAW focus — the "
                       ~ "quantum is dormant", r.focusY));
    }
}

// -------------------------------------------------------------------------
// 2. The quantum FOLLOWS THE ZOOM.
//
// This is what separates "ten grid steps" from "a constant that happens to
// equal ten grid steps at one camera" — the reading that cost this term two
// rounds of being called a contradiction. The same focus, at two zooms whose
// grid steps differ, must land on two different multiples.
// -------------------------------------------------------------------------
unittest {
    // Near: step 0.2 -> quantum 2.0 -> 1.40 rounds to 2.0.
    // Far:  a ten-times distance is a ten-times step (the ladder is closed
    //       under x10) -> quantum 20.0 -> 1.40 rounds to 0.0.
    setup(1.40f, 3.86f);
    immutable double stepNear = gridStep();
    clickOffGizmo();
    immutable double nearY = floatAttr(getAcenAttrs(), "cenY");

    setup(1.40f, 38.6f);
    immutable double stepFar = gridStep();
    clickOffGizmo();
    immutable double farY = floatAttr(getAcenAttrs(), "cenY");

    assert(abs(stepFar - 10.0 * stepNear) < 1e-4 * stepFar,
        format("precondition: ten times the distance must be ten times the "
               ~ "step, got %.6f and %.6f", stepNear, stepFar));
    assert(abs(nearY - dnint(1.40 / (10.0 * stepNear)) * (10.0 * stepNear)) < 1e-3,
        format("near zoom: expected %.4f, got %.6f",
               dnint(1.40 / (10.0 * stepNear)) * (10.0 * stepNear), nearY));
    assert(abs(farY - dnint(1.40 / (10.0 * stepFar)) * (10.0 * stepFar)) < 1e-3,
        format("far zoom: expected %.4f, got %.6f",
               dnint(1.40 / (10.0 * stepFar)) * (10.0 * stepFar), farY));
    assert(abs(nearY - farY) > 1e-2,
        format("the same focus must land differently at two zooms whose steps "
               ~ "differ tenfold — got %.6f at both, so the quantum is a "
               ~ "constant and not the grid's", nearY));
}

// -------------------------------------------------------------------------
// 3. Changing the LADDER changes the quantum.
//
// The grid step is the only input; nothing else about the camera moves. If
// the quantum came from anywhere but `viewgrid`, this row cannot move.
// -------------------------------------------------------------------------
unittest {
    scope(exit) postJson("/api/command",
                         `{"id":"viewport.gridSteps","params":"5"}`);

    setup(1.40f, 3.86f);
    postJson("/api/command", `{"id":"viewport.gridSteps","params":"5"}`);
    settle();
    immutable double step5 = gridStep();
    clickOffGizmo();
    immutable double y5 = floatAttr(getAcenAttrs(), "cenY");

    setup(1.40f, 3.86f);
    postJson("/api/command", `{"id":"viewport.gridSteps","params":"0"}`);
    settle();
    immutable double step0 = gridStep();
    clickOffGizmo();
    immutable double y0 = floatAttr(getAcenAttrs(), "cenY");

    assert(abs(step0 - step5) > 1e-4,
        format("precondition: the two ladders must give different steps, got "
               ~ "%.6f and %.6f", step5, step0));
    assert(abs(y5 - dnint(1.40 / (10.0 * step5)) * (10.0 * step5)) < 1e-3,
        format("ladder {1,2,5,10}: expected %.4f, got %.6f",
               dnint(1.40 / (10.0 * step5)) * (10.0 * step5), y5));
    assert(abs(y0 - dnint(1.40 / (10.0 * step0)) * (10.0 * step0)) < 1e-3,
        format("ladder {1,10}: expected %.4f, got %.6f",
               dnint(1.40 / (10.0 * step0)) * (10.0 * step0), y0));
    assert(abs(y5 - y0) > 1e-2,
        "the pivot must move when the LADDER changes and nothing else does — "
        ~ "otherwise the quantum is not reading the grid");
}
