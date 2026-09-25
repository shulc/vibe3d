// The transform family under the tool session model's command close (slice M2,
// doc/tool_session_model_plan_2026-09-24.md R4.9; captures C-H5-xfrm,
// C-H1-xfrm-rot/-scl, C-H1-xfrm-elem-b in toolcards/tool_session_model, M0b).
//
//   (x1) TransformRotate: a live rotation, then a MOTIONLESS press -> the
//        panel's rotation reads 0 and the geometry stays where the rotation
//        left it (C-H5-xfrm "reset", gap 306);
//   (x2) the same for TransformScale -> the scale reads 1;
//   (x3) Rotate / Scale: a live edit, then the UI `[` (select.invert) -> the
//        transform is still armed and its operation window is open again
//        (re-arm, C-H1-xfrm-rot/-scl `rearmAfterCommand=yes`);
//   (x4) ElementMove: a haul, then the UI `[` -> the tool is armed, its window
//        is NOT open (the Element branch of the resume; C-H1-xfrm-elem-b).
//
// The panel is read from /api/tool/state `values` (the fields its TX..SZ
// params bind). The key is a real SDL event: the UI door.

import http_client : getJson, postJson;
import ssh = symmetry_selection_helpers;

import std.format : format;
import std.json;
import std.math : abs;
import core.thread : Thread;
import core.time : msecs;

void main() {}

enum int K_INVERT = 91;

JSONValue st() { return getJson("/api/tool/state"); }

double[3] vals(string k) {
    auto a = st()["values"][k].array;
    return [ssh.num(a[0]), ssh.num(a[1]), ssh.num(a[2])];
}

string modelText() { return getJson("/api/model")["vertices"].toString; }

/// A motionless press and release off every handle.
void tap(double[3] w) {
    auto p = ssh.px(w);
    ssh.clickPx(p[0], p[1]);
}

void live(string preset, string attr) {
    ssh.rig();
    ssh.selectVerts([6, 7]);
    ssh.cmd("history.clear");
    ssh.cmd("tool.set " ~ preset ~ " on");
    ssh.settle(300);
    ssh.cmd("tool.attr " ~ preset ~ " " ~ attr);
    assert(ssh.toolId() == "xfrm", "xfrm laws rig: " ~ preset ~ " is not armed");
}

enum double[3] OFF = [0.5, -0.3, 0.5];

unittest { // (x1)
    live("TransformRotate", "RY 30");
    const r0 = vals("r");
    assert(abs(r0[1] - 30) < 1e-3, format("x1 floor: RY did not read 30: %s", r0));
    const moved = modelText();
    ssh.assertOffHandle(OFF, "x1 tap");
    tap(OFF);
    const r1 = vals("r");
    assert(abs(r1[0]) < 1e-6 && abs(r1[1]) < 1e-6 && abs(r1[2]) < 1e-6,
           format("x1: a motionless press did not reset the rotation channels: %s", r1));
    assert(modelText() == moved, "x1: the reset moved the geometry");
}

unittest { // (x2)
    live("TransformScale", "SX 1.5");
    const s0 = vals("s");
    assert(abs(s0[0] - 1.5) < 1e-3, format("x2 floor: SX did not read 1.5: %s", s0));
    const moved = modelText();
    ssh.assertOffHandle(OFF, "x2 tap");
    tap(OFF);
    const s1 = vals("s");
    assert(abs(s1[0] - 1) < 1e-6 && abs(s1[1] - 1) < 1e-6 && abs(s1[2] - 1) < 1e-6,
           format("x2: a motionless press did not reset the scale channels: %s", s1));
    assert(modelText() == moved, "x2: the reset moved the geometry");
}

unittest { // (x3)
    foreach (c; [["TransformRotate", "RY 30", "r"], ["TransformScale", "SX 1.5", "s"]]) {
        live(c[0], c[1]);
        ssh.tapKey(K_INVERT);
        auto s = st();
        assert(s.type == JSONType.object && "tool" in s.object && s["tool"].str == "xfrm",
               "x3 " ~ c[0] ~ ": the UI command dropped the transform: " ~ s.toString);
        assert(s["sessionOpen"].type == JSONType.true_,
               "x3 " ~ c[0] ~ ": the transform did not re-open its window after the command");
        const v = vals(c[2]);
        const want = c[2] == "r" ? 0.0 : 1.0;
        assert(abs(v[0] - want) < 1e-6 && abs(v[1] - want) < 1e-6 && abs(v[2] - want) < 1e-6,
               format("x3 %s: the re-arm kept the previous channels: %s", c[0], v));
    }
}

unittest { // (x4)
    ssh.rig();
    ssh.selectVerts([]);
    ssh.cmd("select.typeFrom vertex");
    ssh.cmd("history.clear");
    ssh.cmd("tool.set ElementMove on");
    ssh.settle(300);
    const before = modelText();
    ssh.haul([0.5, 0.5, 0.5], 6, 0, 5);          // pick vertex (0.5,0.5,0.5) and drag it
    assert(modelText() != before, "x4 floor: the element haul moved nothing");
    ssh.tapKey(K_INVERT);
    auto s = st();
    assert(s.type == JSONType.object && "tool" in s.object && s["tool"].str == "xfrm",
           "x4: the UI command dropped ElementMove: " ~ s.toString);
    assert(s["sessionOpen"].type == JSONType.false_,
           "x4: ElementMove re-opened its window after the command (C-H1-xfrm-elem-b: it does not)");
}

// ---------------------------------------------------------------------------
// The re-arm key is the PRESET, not the action centre (slice M3; C-rearm-key,
// gap 370 — toolcards/tool_session_model M0d). `rearmAfterCommand` is preset
// data (config/tool_presets.yaml), read by the session.
//   (x5) C-rearm-a: TransformMove with an Element centre set BY HAND re-arms.
//   (x6) C-rearm-b1: ElementMove with a Selection centre set BY HAND does not.
// Both are red on a binary that keyed the re-arm on the centre mode.
// ---------------------------------------------------------------------------

/// Arm `preset`, set the action centre BY HAND, then a live numeric edit.
void liveUnderCentre(string preset, string mode, string attr) {
    ssh.rig();
    ssh.selectVerts([6, 7]);
    ssh.cmd("history.clear");
    ssh.cmd("tool.set " ~ preset ~ " on");
    ssh.settle(300);
    ssh.cmd("tool.pipe.attr actionCenter mode " ~ mode);
    ssh.cmd("tool.attr " ~ preset ~ " " ~ attr);
    assert(ssh.toolId() == "xfrm", "rearm rig: " ~ preset ~ " is not armed");
}

unittest { // (x5) C-rearm-a
    liveUnderCentre("TransformMove", "element", "TX 0.3");
    ssh.tapKey(K_INVERT);
    auto s = st();
    assert(s.type == JSONType.object && "tool" in s.object && s["tool"].str == "xfrm",
           "x5 C-rearm-a: the UI command dropped TransformMove: " ~ s.toString);
    assert(s["sessionOpen"].type == JSONType.true_,
           "x5 C-rearm-a: TransformMove under a hand-set Element centre did not re-open its "
           ~ "window after the command (the re-arm is the preset's, not the centre's)");
}

unittest { // (x6) C-rearm-b1
    liveUnderCentre("ElementMove", "select", "TX 0.3");
    ssh.tapKey(K_INVERT);
    auto s = st();
    assert(s.type == JSONType.object && "tool" in s.object && s["tool"].str == "xfrm",
           "x6 C-rearm-b1: the UI command dropped ElementMove: " ~ s.toString);
    assert(s["sessionOpen"].type == JSONType.false_,
           "x6 C-rearm-b1: ElementMove under a hand-set Selection centre re-opened its window "
           ~ "after the command (the re-arm is the preset's, not the centre's)");
}
