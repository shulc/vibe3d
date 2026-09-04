// The AXIS stage's per-mode FRAME — the input that is not the action centre.
//
// The transform pipe hands the tools TWO things: a point (the action centre)
// and a frame (the axis basis). The reference pairs an independent axis tool
// with each action-centre tool in its shipped presets, and a recording proved
// the pairing is causal and SEPARABLE: two modes handed over a bit-identical
// centre — nine digits — and still elected different axes, because their axis
// tools differ. Our `actr.*` table has exactly that shape, and this file pins
// the frame half of it.
//
// ── WHY A FILE OF ITS OWN, AND WHY THE DRAG BELOW IS A HANDLE DRAG ────────
//
// Two modes had their frames crossed with each other: `local` returned the
// world axes where the recording gives the selected face's frame, and
// `selectauto` returned the face frame where the recording gives the world
// axes. NEITHER SHOWED UP ANYWHERE. The reference-comparison drag corpus has
// `move_*_local`, `rotate_*_local` and `*_selectauto` legs and every one of them
// stayed green across the fix, which is not evidence of anything — the corpus
// drives an OFF-HANDLE drag, and the off-handle scale election is blind to this
// change by arithmetic, not by luck:
//
//   local BEFORE, frame (+X, +Y, +Z):  |A.E| = (0.482, 0.072, 0.873) -> drop 2
//                                      -> survivors are the frame's 0 and 1
//                                      -> world X takes h, world Y takes v
//   local AFTER,  frame (+X, -Z, +Y):  |A.E| = (0.482, 0.873, 0.072) -> drop 1
//                                      -> survivors are the frame's 0 and 2
//                                      -> world X takes h, world Y takes v
//
// Different frame, different elected INDEX, and the SAME two world axes driven
// by the same two screen components. A vertical drag does not separate them
// either, because the vertical survivor is world Y on both rows. `selectauto`
// is the same story mirrored. So the corpus cannot see this and a green corpus
// must not be quoted as if it could.
//
// What the frame DOES decide, always and visibly, is which gizmo handle is
// which world direction — the frame's slots ARE the handles. Dragging the `up`
// handle moves the selection along whatever `up` is. That is the discriminator
// this file uses, and it is maximal: the two routes send the same handle down
// two different world axes.
//
// ── THE GROUND TRUTH ──────────────────────────────────────────────────────
//
// A recording of the reference on this exact rig — a unit cube with its +Y face
// selected, at the corpus's own base camera — gives, per action-centre preset:
//
//     auto        identity          origin      identity
//     select      (+X, -Z, +Y)      border      (+X, -Z, +Y)
//     local       (+X, -Z, +Y)      selectauto  identity
//
// `select` and `selectauto` hand over the SAME centre there, (0, 0.5, 0), to
// nine digits. That pair is the whole finding stated in one row: a frame that
// varies while the centre does not.
//
// ── WHAT THIS FILE DOES NOT PIN ───────────────────────────────────────────
//
// The selection basis is now the ORIENTED bounding box of the selection
// (`source/toolpipe/obbox.d`, and `tests/test_axis_oriented_box.d` for the
// frame it produces). It USED to snap the averaged face normal to the nearest
// world axis, which agrees with an oriented box exactly on an axis-aligned
// subject — every rig recorded — and answers a signed world permutation on a
// rotated one.
//
// This file is about the mode ROUTING, not about the frame's content, so the
// rotated case below still asserts only what THIS file is responsible for:
// that Local and Select agree, and that both still TRACK the selection rather
// than collapsing to the world identity. What the rotated frame should BE is
// asserted in `test_axis_oriented_box.d` and nowhere here.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

// The corpus's own rig: a unit cube with the +Y face (index 4) selected.
enum string SEL_TOP_FACE = `{"mode":"polygons","indices":[4]}`;

struct Frame {
    Vec3 right, up, fwd;
    Vec3 center;
}

void ok(char[] resp, string what) {
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           what ~ " failed: " ~ cast(string)resp);
}

// Install an `actr.<mode>` preset on the given selection and read back the
// frame AND the centre the pipe published — the two inputs, together, because
// the point of this file is that they move independently.
Frame frameFor(string actr, string sel = SEL_TOP_FACE) {
    post(BASE ~ "/api/reset", "");
    ok(post(BASE ~ "/api/command", commandBody("mesh.select", sel)), "select");
    ok(post(BASE ~ "/api/script", "actr." ~ actr), "actr." ~ actr);
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    Vec3 rd(string slot) {
        auto v = ev["axis"][slot].array;
        return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                    cast(float)v[2].floating);
    }
    auto c = ev["actionCenter"]["center"].array;
    return Frame(rd("right"), rd("up"), rd("fwd"),
                 Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                      cast(float)c[2].floating));
}

string show(Vec3 v) {
    return format("(%.4f, %.4f, %.4f)", v.x, v.y, v.z);
}

void assertFrame(Frame f, Vec3 r, Vec3 u, Vec3 w, string mode, string why) {
    void one(Vec3 got, Vec3 want, string slot) {
        assert(fabs(got.x - want.x) < 1e-4 && fabs(got.y - want.y) < 1e-4
               && fabs(got.z - want.z) < 1e-4,
               "actr." ~ mode ~ ": " ~ slot ~ " must be " ~ show(want)
               ~ " but is " ~ show(got) ~ ". " ~ why);
    }
    one(f.right, r, "right");
    one(f.up,    u, "up");
    one(f.fwd,   w, "fwd");
}

enum Vec3 PX = Vec3( 1, 0, 0), PY = Vec3(0,  1, 0), PZ = Vec3(0, 0,  1);
enum Vec3 NZ = Vec3( 0, 0, -1);

// ── 1. THE RECORDED TABLE, MODE BY MODE ───────────────────────────────────

unittest { // the four that already matched — the control for the two that did not
    assertFrame(frameFor("auto"), PX, PY, PZ, "auto",
        "the auto axis tool installs the identity, and this row is the "
        ~ "CONTROL: if it moves, the fix to local/selectauto has leaked into "
        ~ "modes it had no business touching");
    assertFrame(frameFor("origin"), PX, PY, PZ, "origin",
        "origin pairs with a single-axis axis tool, which is the identity");
    assertFrame(frameFor("select"), PX, NZ, PY, "select",
        "the selection frame for a +Y face: the normal in slot 2, an "
        ~ "edge-aligned pair in the plane");
    assertFrame(frameFor("border"), PX, NZ, PY, "border",
        "border pairs with the SAME axis tool as select, so its frame must "
        ~ "track select's exactly");
}

unittest { // local — was the world axes, must be the selection's
    auto f = frameFor("local");
    assertFrame(f, PX, NZ, PY, "local",
        "local's global frame is the selection's, the same computation select "
        ~ "runs. up = (0,1,0) here means it has fallen back to the world axes, "
        ~ "which is what this stage returned before the frames were measured");
}

unittest { // selectauto — was the selection frame, must be the world axes
    auto f = frameFor("selectauto");
    assertFrame(f, PX, PY, PZ, "selectauto",
        "selectauto pairs the SELECTION action centre with the AUTO axis tool. "
        ~ "up = (0,0,-1) here means it is running select's basis, which is what "
        ~ "this stage returned before the pairing was read");
}

unittest { // THE SEPARABILITY PROPERTY — one centre, two frames
    // This is the row no centre-only rule can produce, and the reason the two
    // inputs have to be modelled separately at all. If a later refactor ever
    // derives the frame FROM the action-centre mode, this is the assertion that
    // catches it: these two modes share a centre by construction.
    auto sel = frameFor("select");
    auto sa  = frameFor("selectauto");
    assert(fabs(sel.center.x - sa.center.x) < 1e-6
           && fabs(sel.center.y - sa.center.y) < 1e-6
           && fabs(sel.center.z - sa.center.z) < 1e-6,
           "select and selectauto must hand over the SAME action centre — the "
           ~ "recording has them bit-identical at (0, 0.5, 0) — but ours are "
           ~ show(sel.center) ~ " and " ~ show(sa.center) ~ ". Without that "
           ~ "the frame comparison below proves nothing");
    assert(fabs(sel.center.y - 0.5f) < 1e-6,
           "and that shared centre must be the selected face's, y = 0.5; got "
           ~ sel.center.y.to!string);
    assert(fabs(sel.up.z - sa.up.z) > 0.5f,
           "...and they must nonetheless install DIFFERENT frames: select's up "
           ~ "is " ~ show(sel.up) ~ ", selectauto's is " ~ show(sa.up)
           ~ ". Equal frames on an equal centre means the axis slot has stopped "
           ~ "being an independent input");
}

// ── 2. THE DISCRIMINATING DRAG ────────────────────────────────────────────
//
// The frame's slots ARE the gizmo's handles: part 0 = right, part 1 = up,
// part 2 = fwd. So the `up` handle is the one the two crossed modes disagree
// about, and dragging it resolves the disagreement into world geometry.

// Drag one move-gizmo handle by a fixed screen offset and report the largest
// per-vertex movement on each world axis. The offset is diagonal so the drag
// has a component along the handle whichever way it projects.
double[3] dragHandle(string actr, int part, string sel = SEL_TOP_FACE) {
    post(BASE ~ "/api/reset", "");
    ok(post(BASE ~ "/api/command", commandBody("mesh.select", sel)), "select");
    ok(post(BASE ~ "/api/script", "tool.set move"), "tool.set move");
    ok(post(BASE ~ "/api/script", "actr." ~ actr), "actr." ~ actr);

    double sx, sy; bool found;
    fetchHandlePart(part, sx, sy, found);
    assert(found, "actr." ~ actr ~ ": move handle part " ~ part.to!string
                  ~ " is not on screen — the drag below would be a no-op");

    double[3][8] pre;
    foreach (i; 0 .. 8) pre[i] = vertexPos(i);

    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             cast(int)sx, cast(int)sy,
                             cast(int)sx + 90, cast(int)sy - 60, 20));

    double[3] worst = [0, 0, 0];
    foreach (i; 0 .. 8) {
        auto p = vertexPos(i);
        foreach (k; 0 .. 3) {
            immutable double d = fabs(p[k] - pre[i][k]);
            if (d > worst[k]) worst[k] = d;
        }
    }
    return worst;
}

// The handle moved along world axis `along` and NOT along `notAlong`.
void assertMovedAlong(double[3] d, int along, int notAlong,
                      string what, string why) {
    static immutable string[3] AX = ["X", "Y", "Z"];
    assert(d[along] > 0.05,
           what ~ ": world " ~ AX[along] ~ " had to move and moved only "
           ~ d[along].to!string ~ ". " ~ why);
    assert(d[notAlong] < 1e-4,
           what ~ ": world " ~ AX[notAlong] ~ " had to stay put and moved by "
           ~ d[notAlong].to!string ~ ". " ~ why);
}

unittest { // local's `up` handle drags along world Z, not world Y
    auto d = dragHandle("local", 1);
    assertMovedAlong(d, 2, 1, "actr.local, up handle",
        "local's frame puts the +Y face normal in slot 2, so slot 1 — the up "
        ~ "handle — is world -Z. Y moving instead is the pre-fix behaviour: "
        ~ "the world-axis fallback, where slot 1 is +Y");
}

unittest { // selectauto's `up` handle drags along world Y, not world Z
    auto d = dragHandle("selectauto", 1);
    assertMovedAlong(d, 1, 2, "actr.selectauto, up handle",
        "selectauto takes the AUTO frame, whose slot 1 is world +Y. Z moving "
        ~ "instead is the pre-fix behaviour: select's face frame, where slot 1 "
        ~ "is -Z");
}

unittest { // the two must DISAGREE — the property, stated once
    // Each assertion above is satisfiable by a stage that ignores the mode
    // entirely and hard-codes one frame; this one is not. It is also the case
    // that fails on the pre-fix stage from BOTH sides at once, since the old
    // routing had these two modes' frames swapped rather than merely wrong.
    auto lo = dragHandle("local", 1);
    auto sa = dragHandle("selectauto", 1);
    assert(lo[2] > 0.05 && sa[1] > 0.05,
           "one gizmo handle must send local down world Z and selectauto down "
           ~ "world Y; got local Z = " ~ lo[2].to!string ~ ", selectauto Y = "
           ~ sa[1].to!string);
    assert(!(lo[2] > 0.05 && sa[2] > 0.05),
           "local and selectauto must not send the up handle down the SAME "
           ~ "world axis — that is the collapsed state the fix separates, and "
           ~ "it reads identically whether both took the selection frame or "
           ~ "both took the world one");
    // The control: the two modes agree about the OTHER two handles, so the
    // divergence is the frame's second slot and not the whole gizmo drifting.
    auto lo0 = dragHandle("local", 0);
    auto sa0 = dragHandle("selectauto", 0);
    assert(lo0[0] > 0.05 && sa0[0] > 0.05,
           "both modes' `right` handle is world +X and must move X: got "
           ~ lo0[0].to!string ~ " and " ~ sa0[0].to!string);
}

// ── 3. A ROTATED SUBJECT ──────────────────────────────────────────────────

// A unit cube rotated 30 degrees about world X, so no face normal is a world
// axis. Face 4 is the one that was +Y; its normal is now 30 degrees off it.
enum string ROTATED_CUBE = `{"vertices":[`
    ~ `[-0.5,-0.183013,-0.683013],[0.5,-0.183013,-0.683013],`
    ~ `[0.5,0.683013,-0.183013],[-0.5,0.683013,-0.183013],`
    ~ `[-0.5,-0.683013,0.183013],[0.5,-0.683013,0.183013],`
    ~ `[0.5,0.183013,0.683013],[-0.5,0.183013,0.683013]],`
    ~ `"faces":[[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]]}`;

unittest { // Local and Select stay in lockstep off the world axes too
    ok(post(BASE ~ "/api/reset", ""), "reset");
    auto lm = post(BASE ~ "/api/load-mesh", ROTATED_CUBE);
    assert(parseJSON(cast(string)lm)["status"].str == "ok",
           "load-mesh failed: " ~ cast(string)lm);
    ok(post(BASE ~ "/api/command", commandBody("mesh.select", SEL_TOP_FACE)), "select");

    Frame read(string actr) {
        ok(post(BASE ~ "/api/script", "actr." ~ actr), "actr." ~ actr);
        auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
        Vec3 rd(string slot) {
            auto v = ev["axis"][slot].array;
            return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                        cast(float)v[2].floating);
        }
        return Frame(rd("right"), rd("up"), rd("fwd"), Vec3(0, 0, 0));
    }
    auto sel = read("select");
    auto loc = read("local");
    auto sa  = read("selectauto");

    // NOT ASSERTED HERE, DELIBERATELY: what `sel.fwd` should be. That is the
    // oriented box's business and it is pinned, exactly, in
    // `test_axis_oriented_box.d`. This file asserts the ROUTING — which mode
    // reads which frame — and duplicating the frame's value here would mean
    // two files to update for one law.
    assert(fabs(sel.up.x - loc.up.x) < 1e-5 && fabs(sel.up.y - loc.up.y) < 1e-5
           && fabs(sel.up.z - loc.up.z) < 1e-5,
           "local and select run one computation and must agree on a rotated "
           ~ "subject too; got select up " ~ show(sel.up) ~ " and local up "
           ~ show(loc.up));
    // Both still TRACK the selection: the frame is not the world identity.
    //
    // This assertion was written as `fabs(loc.up.y - 1.0f) > 0.5f` — one
    // component of one slot — because at the time `up` on a rotated subject
    // was the SNAPPED world -Z and `up.y` was 0. The oriented-box port makes
    // the correct answer `up = (0, 0.5, -0.866)`, so the old form evaluated
    // `0.5 > 0.5`: FALSE, on the threshold, and worse than that — `up.y` is
    // numerically `fwd.z` there, so which side of the threshold it landed on
    // was float noise. A boundary coin-flip cannot state "the frame is not the
    // world identity".
    //
    // Restated on the whole frame, which is what the sentence above always
    // meant: the largest deviation of ANY slot from the world identity. On the
    // oriented answer that is 0.866 (both `up` and `fwd` are 30 degrees off
    // their world axes), so the margin is real, and the statement now also
    // catches a frame that went identity in `right` or `fwd` while `up`
    // happened not to.
    float idDev = 0;
    foreach (i, pair; [[loc.right, PX], [loc.up, PY], [loc.fwd, PZ]]) {
        foreach (d; [fabs(pair[0].x - pair[1].x), fabs(pair[0].y - pair[1].y),
                     fabs(pair[0].z - pair[1].z)])
            if (d > idDev) idDev = d;
    }
    assert(idDev > 0.5f,
           "local must still take the selection's frame on a rotated subject; "
           ~ "the frame " ~ show(loc.right) ~ " " ~ show(loc.up) ~ " "
           ~ show(loc.fwd) ~ " is within " ~ idDev.to!string
           ~ " of the world identity, i.e. it has fallen back");
    // And selectauto still does not.
    assert(fabs(sa.up.y - 1.0f) < 1e-5,
           "selectauto must take the AUTO frame whatever the subject's "
           ~ "orientation; got up = " ~ show(sa.up));
}
