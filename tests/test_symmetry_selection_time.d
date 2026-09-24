// Symmetry is a SELECTION-time rule, and a transform under symmetry writes
// only its operand, in one authoring frame (task 7143 — the R half of wave
// slice S3b; the fix is task 7144).
//
// The captured law (tests/fixtures/symmetry_selection_time_laws.json):
//   1. a mirror partner joins the selection only through a POINTER gesture
//      (click, region, loop); script and command doors never pair;
//   2. a transform writes only its operand — an unselected partner is never
//      written, by a move, a rotation or a scale, with or without a falloff;
//   3. every operand vertex is computed in ONE authoring frame A: on side A it
//      takes the transform K, off A it takes M·K(M·p) (the whole affine
//      conjugated, pivot included); a selected PAIR is then an exact mirror
//      copied from its +X member;
//   4. A is a latch, placed wherever an action centre is placed: a transform
//      preset's activation (the handle's side), a press that places the centre
//      (Move, Rotate, Edge Extend — also with symmetry off), switching an
//      action centre on, and the re-activation a selection change triggers
//      while a transform is armed. A outlives a tool drop, a symmetry toggle,
//      an axis round trip and a live undo; a fresh session starts at -X. A press
//      under a PINNED centre does not move it;
//   5. a pair's falloff weight is read at its +X member; an on-plane vertex
//      keeps its plane coordinate.
//
// Two doors, mapped to the capture's two numeric doors: `tool.set <preset> on;
// tool.attr ...; tool.doApply` is "activate, then apply" (the activation
// latches A and the handle is the pivot); `mesh.transform` is the one-block
// door (no activation, pivot at the origin, A only read).
//
// How this file reports. Rig floors fail at once; law checks are collected
// and the file ends with one assert listing every red law check (see
// tests/symmetry_selection_helpers.d). On the pre-fix tree the red set is the
// law, not the rig: every block's floors pass there.
//
// Not here: the one-block door's partner weight on the DRAG door (not captured,
// `capture: manual`); an undo after a tool drop — our undo does not re-arm the
// transform (measured, task card 7143), so the capture's re-activation cell
// has no counterpart to drive.

import symmetry_selection_helpers;
import http_client : getJson;

import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

enum V3 V6 = [0.5, 0.5, 0.5];
enum V3 V7 = [-0.5, 0.5, 0.5];
enum V3 V2 = [0.5, 0.5, -0.5];
enum V3 V3_ = [-0.5, 0.5, -0.5];

/// Press points OFF every handle: below the cube, on +X and on -X.
enum V3 PRESS_POS = [0.5, -0.3, 0.5];
enum V3 PRESS_NEG = [-0.5, -0.3, 0.5];

enum string DEFORMED_MESH =
    `{"vertices":[[0,0,0],[0,1,0],[2.0,0.5,0],[1.5,1.2,0],[-0.8,-0.3,0],[-1.1,1.3,0]],`
    ~ `"faces":[[0,2,3,1],[0,1,5,4]]}`;

enum int KEY_Z = 122, KEY_BRACKET_RIGHT = 93;

// --- the latch rig (7146) -----------------------------------------------------

/// v7 alone (script, symmetry OFF), symmetry X on (unless `symmetryOn` is
/// false), `preset` armed — its activation latches -X — then `beforePress`, a
/// press OFF the handle at +X and a 10 x 8 px haul right. Answers v7's ΔX.
double latchRig(string preset = "move", void delegate() beforePress = null, bool symmetryOn = true) {
    rig();
    immutable int v7 = near(V7);
    selectVerts([v7]);
    if (symmetryOn) symmetry(true);
    cmd("tool.set " ~ preset ~ " on");
    settle(300);
    if (beforePress !is null) beforePress();
    assertOffHandle(PRESS_POS, "latch rig");
    immutable double x0 = verts()[v7][0];
    haul(PRESS_POS, 8, 0, 10);
    return verts()[v7][0] - x0;
}

/// The reading door of every latch cell: v7 alone (by a door that does not
/// pair), `mesh.transform` TX 0.4. Answers v7's ΔX.
double readDx(int vi = 7) {
    cmd("select.typeFrom vertex");
    cmd("select.element vertex set " ~ vi.to!string);
    assert(selV() == [vi], format("rig: the reading selection is %s, expected [%d] alone", selV(), vi));
    immutable double x0 = verts()[vi][0];
    meshTranslate([0.4, 0, 0]);
    return verts()[vi][0] - x0;
}

void dropTool(string preset) {
    if (toolId() != "") cmd("tool.set " ~ preset ~ " off");
    assert(toolId() == "", "rig: the tool is still armed after the drop");
}

int edgeAt(V3 a, V3 b) {
    auto m = getJson("/api/model");
    auto vs = m["vertices"].array;
    foreach (i, e; m["edges"].array) {
        V3 p = vec(vs[e.array[0].integer]), q = vec(vs[e.array[1].integer]);
        if ((near3(p, a, 1e-5) && near3(q, b, 1e-5)) || (near3(p, b, 1e-5) && near3(q, a, 1e-5)))
            return cast(int) i;
    }
    assert(false, "rig: no edge " ~ fmt(a) ~ "-" ~ fmt(b));
}

/// Edge mode, the -X bottom edge alone (by a door that does not pair),
/// symmetry X on, Edge Extend armed.
void extendArm() {
    cmd("select.typeFrom edge");
    cmd("select.element edge set " ~ edgeAt([-0.5, -0.5, 0.5], [-0.5, -0.5, -0.5]).to!string);
    assert(selE().length == 1, "rig: the extend selection is not one edge");
    symmetry(true);
    cmd("tool.set edge.extend on");
    settle(300);
    assert(toolId() == "edgeExtend", "rig: Edge Extend did not arm");
}

// --- blocks -------------------------------------------------------------------

/// Our cube's indices for the four named vertices (index_map's v-names).
void indexFloor() {
    rig();
    assert(near(V6) == 6 && near(V7) == 7 && near(V2) == 2 && near(V3_) == 3,
        "rig: the reset cube's vertex order changed; v2/v3/v6/v7 are not at their named positions");
}

void blockA0() {
    // A symmetric click pairs, and a pair moved in-plane stays a mirror
    // (C-base, click on v6, weight 1 at +X).
    rig();
    symmetry(true);
    click(V6);
    auto s = selV();
    assert(s.length == 2, format("rig: the symmetric click selected %d vertices, expected 2", s.length));
    auto c = cell("C-base")["click_pos_x_w_pos1_neg0"];
    toolApply("move", ["TY 0.4"], { linearFalloff([0.5, 0, 0], [-0.5, 0, 0]); });
    auto v = verts();
    law(near3(v[6], vec(c["pos_after"])) && near3(v[7], vec(c["neg_after"])),
        format("paired move is not mirrored: v6 %s v7 %s, expected %s / %s",
               fmt(v[6]), fmt(v[7]), fmt(vec(c["pos_after"])), fmt(vec(c["neg_after"]))));
}

void blockP() {
    // An on-plane vertex keeps x = 0 (C-plane, P-proj).
    auto c = cell("C-plane");
    cubeRig(2);
    symmetry(true);
    auto rec = c["on_plane_vertex"];
    string key = rec.object.keys[0];
    immutable int vi = near(vec(rec[key]["before"]));
    click(vec(rec[key]["before"]));
    assert(selV().length == c["selection_count"].integer,
        format("rig: the on-plane click selected %s, expected %d vertex", selV(), c["selection_count"].integer));
    toolApply("move", ["TX 0.4", "TY 0.2"]);
    auto got = verts()[vi];
    law(near3(got, vec(rec[key]["after"])),
        format("an on-plane vertex left the plane: %s, expected %s", fmt(got), fmt(vec(rec[key]["after"]))));
}

void blockA() {
    // Tool door (activate, then apply). The first red of the pre-fix tree.
    rig();
    selectVerts([6]);
    symmetry(true);
    assert(selV() == [6], format("rig: partner selected before the move: %s", selV()));
    cmd("tool.set move on");
    sideFloor(1, "A: the activation latched the handle side");
    cmd("tool.attr move TX 0.4");
    cmd("tool.doApply");
    cmd("tool.set move off");
    auto v = verts();
    law(near3(v[7], V7), format("unselected mirror partner moved by the transform: v7 %s, expected %s",
                                fmt(v[7]), fmt(V7)));
    immutable double want = num(cell("C-activation")["pos_x_vertex_after"].array[0]);
    law(abs(v[6][0] - want) <= 1e-3,
        format("activation latched the handle side: v6.x %.4f, expected %g", v[6][0], want));
}

void blockB() {
    // One-block door (`mesh.transform`), fresh session: A = -X.
    auto c = cell("C-order");
    rig();
    selectVerts([6]);
    symmetry(true);
    assert(selV() == [6], format("rig: partner selected before the move: %s", selV()));
    sideFloor(-1, "B: fresh session");
    meshTranslate([0.4, 0, 0]);
    auto v = verts();
    law(near3(v[7], vec(c["v_neg_x_partner_after"])),
        format("mesh.transform moved an unselected mirror partner: v7 %s", fmt(v[7])));
    law(near3(v[6], vec(c["v_pos_x_after"])),
        format("one-block door, fresh session: v6.x %.4f, expected %g (authored on -X)",
               v[6][0], vec(c["v_pos_x_after"])[0]));
}

void blockC() {
    // A lone -X vertex is on A: own delta; its partner is never written.
    auto c = cell("C-lone-neg");
    rig();
    selectVerts([7]);
    symmetry(true);
    assert(selV() == [7], format("rig: partner selected before the move: %s", selV()));
    sideFloor(-1, "C: fresh session");
    meshTranslate([0.4, 0, 0]);
    auto v = verts();
    law(near3(v[6], vec(c["partner_after"])),
        format("a lone -X vertex wrote its unselected partner: v6 %s", fmt(v[6])));
    law(near3(v[7], vec(c["selected_after"])),
        format("lone -X vertex on A: v7.x %.4f, expected %g", v[7][0], vec(c["selected_after"])[0]));
}

void deformedRig() {
    rig();
    cmd(`{"id":"scene.loadMesh","params":` ~ DEFORMED_MESH ~ `}`);
    selectVerts([2]);
    cmd("tool.pipe.attr symmetry topology true");
    symmetry(true);
    auto sy = getJson("/api/toolpipe/eval")["symmetry"];
    assert(sy["pairOf"].array[2].integer == 4, "rig: pairOf[2] is not 4 on the deformed rig: " ~ sy["pairOf"].toString);
    assert(selV() == [2], format("rig: the deformed rig's selection is %s, expected [2]", selV()));
}

void blockD() {
    // Topology-paired partner of a deformed base: the delta mirror must not
    // write it either (both doors). Only v4 is compared.
    enum V3 D0 = [-0.8, -0.3, 0];
    deformedRig();
    meshTranslate([0.5, 0.3, 0.1]);
    auto v4 = verts()[4];
    law(near3(v4, D0), format("delta mirror wrote an unselected partner: v4 %s, expected %s (mesh.transform)",
                              fmt(v4), fmt(D0)));
    deformedRig();
    toolApply("move", ["TX 0.5", "TY 0.3", "TZ 0.1"]);
    v4 = verts()[4];
    law(near3(v4, D0), format("delta mirror wrote an unselected partner: v4 %s, expected %s (tool door, routed)",
                              fmt(v4), fmt(D0)));
}

void blockE() {
    // The falloff does not widen the operand; the lone vertex takes its own weight.
    auto c = cell("C-fall");
    rig();
    selectVerts([6]);
    symmetry(true);
    toolApply("move", ["TY 0.4"], { linearFalloff([-1, 0, 0], [1, 0, 0]); });
    auto v = verts();
    law(near3(v[6], vec(c["selected_after"])),
        format("lone vertex weight: v6 ΔY %.4f, expected %.4f", v[6][1] - 0.5, vec(c["selected_after"])[1] - 0.5));
    law(near3(v[7], vec(c["partner_after"])),
        format("falloff-reached unselected partner moved: v7 ΔY %.4f, expected 0", v[7][1] - 0.5));
}

void blockG() {
    // One authoring frame for a pair and a lone vertex (C-mixed), one-block door.
    auto c = cell("C-mixed");
    rig();
    int[] sel;
    int[string] ours;
    foreach (key, rec; c["moved"].object) {
        ours[key] = mapKey(key, vec(rec["before"]));
        sel ~= ours[key];
    }
    assert(sel.length == 3, "rig: C-mixed moves 3 vertices");
    immutable int n3 = near(V3_);
    selectVerts(sel);
    symmetry(true);
    assert(selV().length == 3, format("rig: C-mixed selection is %s", selV()));
    sideFloor(-1, "G: fresh session");
    meshTranslate([0.4, 0, 0]);
    auto v = verts();
    bool ok = near3(v[n3], vec(c["unselected_partner_after"]));
    string got, want;
    foreach (key, rec; c["moved"].object) {
        ok = ok && near3(v[ours[key]], vec(rec["after"]));
        got ~= format(" v%d %s", ours[key], fmt(v[ours[key]]));
        want ~= format(" v%d %s", ours[key], fmt(vec(rec["after"])));
    }
    law(ok, format("one authoring frame:%s v3 %s, expected%s v3 %s", got, fmt(v[n3]), want,
                   fmt(vec(c["unselected_partner_after"]))));

    // A pair's weight is read at its +X member, whichever side was clicked.
    auto b = cell("C-base")["click_neg_x_w_neg1_pos0"];
    rig();
    symmetry(true);
    click(V7);
    assert(selV().length == 2, format("rig: the symmetric click on v7 selected %s", selV()));
    toolApply("move", ["TY 0.4"], { linearFalloff([-0.5, 0, 0], [0.5, 0, 0]); });
    v = verts();
    law(near3(v[6], vec(b["pos_after"])) && near3(v[7], vec(b["neg_after"])),
        format("pair weight read at the +X member: ΔY %.4f / %.4f, expected 0", v[6][1] - 0.5, v[7][1] - 0.5));
}

void blockG2() {
    // A clicked pair, then the tool door: the handle is the +X member, so the
    // activation latches +X (composition of the pair-handle and activation cells).
    rig();
    symmetry(true);
    click(V6);
    assert(selV().length == 2, format("rig: the symmetric click selected %s", selV()));
    cmd("tool.set move on");
    sideFloor(1, "G2: pair activation");
    cmd("tool.attr move TX 0.4");
    cmd("tool.doApply");
    cmd("tool.set move off");
    auto v = verts();
    law(abs(v[6][0] - 0.9) <= 1e-3 && abs(v[7][0] + 0.9) <= 1e-3,
        format("pair activation latched the wrong side: v6.x %.4f v7.x %.4f, expected 0.9/-0.9", v[6][0], v[7][0]));
}

void blockU() {
    // A vertex with no partner still follows the side rule (C-unpaired).
    auto c = cell("C-unpaired");
    rig();
    selectVerts([7]);
    meshTranslate([0, 0, 0.2]);
    assert(near3(verts()[7], [-0.5, 0.5, 0.7]), "rig: v7 did not move to (-0.5,0.5,0.7)");
    selectVerts([6]);
    symmetry(true);
    sideFloor(-1, "U: fresh session");
    meshTranslate([0.4, 0, 0]);
    auto v = verts();
    law(near3(v[6], vec(c["selected_after"])),
        format("unpaired vertex off A: v6.x %.4f, expected %g", v[6][0], vec(c["selected_after"])[0]));
}

void blockH() {
    // Rotation, one-block door: the conjugate off A; the partner never written.
    auto r60 = cell("C-rot");
    rig();
    selectVerts([6]);
    meshRotateY(60);
    assert(near3(verts()[6], vec(r60["control_symmetry_off_selected_after"])),
        format("rig: mesh.transform rotate disagrees with the capture's RY sign or unit: v6 %s, control %s",
               fmt(verts()[6]), fmt(vec(r60["control_symmetry_off_selected_after"]))));

    auto r45 = cell("C-rot45");
    rig();
    selectVerts([6]);
    symmetry(true);
    sideFloor(-1, "H: fresh session");
    meshRotateY(45);
    auto v = verts();
    law(near3(v[7], vec(r45["partner_after"])), format("rotate wrote an unselected mirror partner: v7 %s", fmt(v[7])));
    law(near3(v[6], vec(r45["selected_after"])),
        format("rotation off A is the conjugate: v6 %s, expected %s", fmt(v[6]), fmt(vec(r45["selected_after"]))));

    rig();
    selectVerts([6]);
    symmetry(true);
    meshRotateY(60);
    v = verts();
    law(near3(v[6], vec(r60["selected_after"])) && near3(v[7], vec(r60["partner_after"])),
        format("rotation 60 off A: v6 %s v7 %s, expected %s / %s", fmt(v[6]), fmt(v[7]),
               fmt(vec(r60["selected_after"])), fmt(vec(r60["partner_after"]))));

    rig();
    selectVerts([6, 7]);
    symmetry(true);
    meshRotateY(60);
    v = verts();
    auto ps = r60["pair_selected"];
    law(near3(v[6], vec(ps["pos_after"])) && near3(v[7], vec(ps["neg_after"])),
        format("rotated pair: v6 %s v7 %s, expected %s / %s (the -X member takes the typed rotation)",
               fmt(v[6]), fmt(v[7]), fmt(vec(ps["pos_after"])), fmt(vec(ps["neg_after"]))));
}

void blockH2() {
    // H'': the one-block door pivots on the origin (gap 329).
    auto np = cell("numeric_door_pivot");
    rig();
    selectVerts([7]);
    symmetry(true);
    sideFloor(-1, "H'': fresh session");
    meshRotateY(45);
    auto v = verts();
    law(near3(v[7], vec(np["lone_on_authoring_side_rotate_45"])),
        format("one-block door pivot is not the origin: v7 %s, expected %s", fmt(v[7]),
               fmt(vec(np["lone_on_authoring_side_rotate_45"]))));
    law(near3(v[6], V6), format("rotate wrote an unselected mirror partner: v6 %s (lone -X vertex)", fmt(v[6])));

    auto tw = cell("C-rot-self")["twins"]["pair_same_side_no_activation"];
    rig();
    selectVerts([6, near(V2)]);
    symmetry(true);
    sideFloor(-1, "H'' twin: fresh session");
    meshRotateY(45);
    v = verts();
    law(near3(v[6], vec(tw["a_after"])) && near3(v[2], vec(tw["b_after"])),
        format("same-side pair, no activation: v6 %s v2 %s, expected %s / %s", fmt(v[6]), fmt(v[2]),
               fmt(vec(tw["a_after"])), fmt(vec(tw["b_after"]))));
}

void blockH3() {
    // H': after activation the off-A vertex conjugates the WHOLE affine,
    // pivot included (Cj-affine). Rotate and scale twins.
    auto tr = cell("C-rot-self")["twins"]["mixed_sides_after_activation"];
    rig();
    immutable int a = near(V6), b = near(V2), n = near(V3_);
    selectVerts([a, b, n]);
    symmetry(true);
    cmd("tool.set TransformRotate on");
    assert(near3(acenCentre(), [0.5, 0.5, 0]), "rig: the handle is not the +X-half centroid: " ~ fmt(acenCentre()));
    sideFloor(1, "H': rotate activation");
    cmd("tool.attr TransformRotate RY 45");
    cmd("tool.doApply");
    cmd("tool.set TransformRotate off");
    auto v = verts();
    law(near3(v[a], vec(tr["pos_a_after"])) && near3(v[b], vec(tr["pos_b_after"]))
            && near3(v[n], vec(tr["neg_after"])),
        format("conjugate pivot: %s/%s/%s, expected %s/%s/%s", fmt(v[a]), fmt(v[b]), fmt(v[n]),
               fmt(vec(tr["pos_a_after"])), fmt(vec(tr["pos_b_after"])), fmt(vec(tr["neg_after"]))));
    law(near3(v[7], V7),
        format("rotate wrote an unselected mirror partner: v7 %s (mixed selection)", fmt(v[7])));

    auto ts = cell("C-scale-self")["twins"]["mixed_sides_after_activation"];
    cubeRig(4);
    immutable int sa = near([0.5, 0.5, 0.5]), sb = near([0.25, 0.5, 0.5]), sn = near([-0.5, 0.5, -0.5]);
    immutable int pa = near([-0.5, 0.5, 0.5]), pb = near([-0.25, 0.5, 0.5]);
    selectVerts([sa, sb, sn]);
    symmetry(true);
    cmd("tool.set TransformScale on");
    assert(abs(acenCentre()[0] - 0.375) <= 1e-4, "rig: the scale handle x is not 0.375: " ~ fmt(acenCentre()));
    sideFloor(1, "H': scale activation");
    cmd("tool.attr TransformScale SX 2");
    cmd("tool.doApply");
    cmd("tool.set TransformScale off");
    v = verts();
    law(near3(v[sa], vec(ts["a_after"])) && near3(v[sb], vec(ts["b_after"])) && near3(v[sn], vec(ts["neg_after"])),
        format("conjugate scale pivot: %s/%s/%s, expected %s/%s/%s", fmt(v[sa]), fmt(v[sb]), fmt(v[sn]),
               fmt(vec(ts["a_after"])), fmt(vec(ts["b_after"])), fmt(vec(ts["neg_after"]))));
    law(near3(v[pa], [-0.5, 0.5, 0.5]) && near3(v[pb], [-0.25, 0.5, 0.5]),
        format("scale wrote unselected mirror partners: %s / %s", fmt(v[pa]), fmt(v[pb])));
}

void blockI() {
    // A drag press latches the press side: off-handle press at -X authors on
    // -X (the +X vertex moves AGAINST the hand), at +X on +X (with the hand).
    // Absolute numbers are not compared (pixel-to-world differs).
    foreach (pressAt; [PRESS_NEG, PRESS_POS]) {
        rig();
        selectVerts([6]);
        symmetry(true);
        cmd("tool.set move on");
        settle(300);
        assertOffHandle(pressAt, "I");
        auto v0 = verts();
        haul(pressAt, 8, 0, 10);
        auto v = verts();
        cmd("tool.set move off");
        immutable double dx = v[6][0] - v0[6][0];
        assert(abs(dx) > 0.05 || abs(v[6][1] - v0[6][1]) > 0.05, format("rig: the haul moved v6 by %s", dx));
        if (pressAt[0] < 0)
            law(dx < -0.05, format("press at -X did not author on -X: ΔX %.4f", dx));
        else
            law(dx > 0.05, format("press at +X did not author on +X: ΔX %.4f", dx));
        law(near3(v[7], V7), format("the drag wrote the unselected partner: v7 %s (press at %s)",
                                    fmt(v[7]), pressAt[0] < 0 ? "-X" : "+X"));
    }
}

void blockJ() {
    // The latch: which events place A and what it outlives (7146/7147).
    // (J2) the side survives a tool drop.
    immutable double haulDx = latchRig();
    law(haulDx < -0.05, format("the +X press did not author the haul on +X: v7 ΔX %.4f, expected < 0", haulDx));
    dropTool("move");
    sideFloor(1, "J2");
    double dx = readDx();
    law(abs(dx - num(cell("C-latch-p")["numeric"]["dx"])) <= 1e-3,
        format("the authoring side did not survive a tool drop: dx %.4f, expected %g", dx,
               num(cell("C-latch-p")["numeric"]["dx"])));

    // (J2') the live regrade of the run reads the latched side.
    latchRig();
    assert(toolId() == "xfrm", "rig: J2' needs the tool still armed");
    cmd("tool.attr move TX 0.4");
    auto v7 = verts()[7];
    dropTool("move");
    law(abs(v7[0] + 0.9) <= 1e-3, format("live regrade lost the authoring side: v7.x %.4f, expected -0.9", v7[0]));

    // (J3) a symmetry toggle keeps the side.
    latchRig();
    dropTool("move");
    symmetry(false);
    symmetry(true);
    sideFloor(1, "J3");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-t")["numeric"]["dx"])) <= 1e-3,
        format("a symmetry toggle reset the side: dx %.4f, expected %g", dx, num(cell("C-latch-t")["numeric"]["dx"])));

    // (J3a) an axis round trip keeps the side.
    latchRig();
    dropTool("move");
    cmd("tool.pipe.attr symmetry axis z");
    cmd("tool.pipe.attr symmetry axis x");
    sideFloor(1, "J3a");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-a")["numeric"]["dx"])) <= 1e-3,
        format("an axis round trip reset the side: dx %.4f, expected %g", dx, num(cell("C-latch-a")["numeric"]["dx"])));

    // (J3o) a press with symmetry OFF still latches.
    immutable double ownDx = latchRig("move", null, false);
    assert(ownDx > 0.05, format("rig: with symmetry off the haul must move v7 with the hand, ΔX %.4f", ownDx));
    dropTool("move");
    symmetry(true);
    sideFloor(1, "J3o");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-t-off")["numeric"]["dx"])) <= 1e-3,
        format("a press with symmetry off did not latch: dx %.4f, expected %g", dx,
               num(cell("C-latch-t-off")["numeric"]["dx"])));

    // (J4) an Edge Extend press sets the same side the transform reads.
    rig();
    extendArm();
    immutable size_t n0 = verts().length;
    assertOffHandle(PRESS_POS, "J4");
    haul(PRESS_POS, 8, 0, 10);
    auto nv = verts()[n0 .. $];
    assert(nv.length == 2, format("rig: the extend haul made %d vertices, expected 2", nv.length));
    foreach (p; nv) assert(p[0] < -0.5, "rig: the extend haul did not author on +X (new edge at " ~ fmt(p) ~ ")");
    dropTool("edge.extend");
    sideFloor(1, "J4");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-x")["numeric"]["dx"])) <= 1e-3,
        format("an extend press did not set the side: dx %.4f, expected %g", dx,
               num(cell("C-latch-x")["numeric"]["dx"])));

    // (J4b) arming Edge Extend, with no press, does not move the side.
    latchRig();
    dropTool("move");
    extendArm();
    dropTool("edge.extend");
    sideFloor(1, "J4b");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3, format("arming the extend tool moved the side: dx %.4f, expected -0.4", dx));

    // (J5) a live undo keeps the side.
    latchRig();
    tapKey(KEY_Z, KMOD_LCTRL);
    settle();
    assert(near3(verts()[7], V7), "rig: the live undo did not restore v7: " ~ fmt(verts()[7]));
    dropTool("move");
    sideFloor(1, "J5");
    dx = readDx();
    immutable double undoWant = num(cell("C-latch-u")["undo_live"]["after"].array[0]);
    law(abs(-0.5 + dx - undoWant) <= 1e-3,
        format("a live undo reset the side: v7.x %.4f, expected %g", -0.5 + dx, undoWant));

    // (J6) switching the origin action centre on latches -X.
    latchRig();
    dropTool("move");
    cmd("actr.origin");
    sideFloor(-1, "J6");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-o")["numeric"]["dx"])) <= 1e-3,
        format("switching the origin action centre on did not latch -X: dx %.4f, expected %+g", dx,
               num(cell("C-latch-o")["numeric"]["dx"])));

    // (J6b) switching a centre on latches AT ONCE, at the centre it places:
    // v6 (+X) selected, the selection centre switched on, then the selection
    // moved to v7 (-X) and the pipeline evaluated. A deferred latch would take
    // the later selection's side (-X). Opponent R25 condition 1.
    rig();
    selectVerts([6]);
    symmetry(true);
    cmd("actr.select");
    cmd("select.element vertex set 7");
    getJson("/api/toolpipe/eval");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3,
        format("switching the selection centre on latched at a later evaluation: dx %.4f, expected -0.4", dx));

    // (J6c) a tool armed and dropped with no evaluation between (one script
    // block) leaves no pending latch behind, also under a user-locked centre:
    // the later evaluation must not latch the then-current selection's side.
    // Opponent R25 condition 2.
    rig();
    selectVerts([6]);
    symmetry(true);
    cmd("actr.select");
    {
        import http_client : postJson;
        auto r = postJson("/api/script", "tool.set move on\ntool.set move off");
        assert(r["status"].str == "ok", "rig: the arm-and-drop script failed: " ~ r.toString);
    }
    assert(toolId() == "", "rig: the arm-and-drop script left a tool armed");
    cmd("select.element vertex set 7");
    getJson("/api/toolpipe/eval");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3,
        format("a dropped activation latched at a later evaluation: dx %.4f, expected -0.4", dx));

    // (J7) inside Edge Extend: apply-and-continue (a Shift press, here on +X
    // again) and history navigation do not reset the side. Our divergence
    // label, not a cell. The navigation rig pops a COMMITTED operation (the one
    // a Shift press opened) — the step that re-syncs the tool's session; a live
    // pop of a gesture never leaves the session. The Shift variant cannot
    // redden a reset in the re-sync by construction: the Shift press is itself
    // an off-handle placement (W4) that re-latches its own side.
    rig();
    extendArm();
    haul(PRESS_POS, 8, 0, 10);
    {
        auto p = px([0.5, -0.4, 0.3]);
        clickPx(p[0], p[1], KMOD_LSHIFT);
    }
    assert(toolId() == "edgeExtend", "rig: the Shift press ended Edge Extend");
    dropTool("edge.extend");
    sideFloor(1, "J7 shift");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3, format("apply-and-continue reset the authoring side: dx %.4f, expected -0.4", dx));

    rig();
    extendArm();
    haul(PRESS_POS, 8, 0, 10);
    {
        auto p = px([0.5, -0.4, 0.3]);
        clickPx(p[0], p[1], KMOD_LSHIFT);
    }
    immutable size_t opened = verts().length;
    tapKey(KEY_Z, KMOD_LCTRL);
    settle();
    assert(toolId() == "edgeExtend" && opened == 12 && verts().length == 10,
        format("rig: Ctrl+Z did not pop the Shift-opened operation whole with the tool kept "
             ~ "(tool '%s', %d -> %d vertices, expected 12 -> 10)", toolId(), opened, verts().length));
    dropTool("edge.extend");
    sideFloor(1, "J7 navigation");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3, format("history navigation reset the authoring side: dx %.4f, expected -0.4", dx));

    // (J8) a rotate press latches like a move press.
    latchRig("TransformRotate");
    dropTool("TransformRotate");
    sideFloor(1, "J8");
    dx = readDx();
    law(abs(dx - num(cell("C-latch-r")["numeric"]["dx"])) <= 1e-3,
        format("a rotate press did not latch: dx %.4f, expected %g", dx, num(cell("C-latch-r")["numeric"]["dx"])));

    // (J-act) a transform activation latches the handle's side.
    rig();
    selectVerts([6]);
    symmetry(true);
    cmd("tool.set move on");
    cmd("tool.set move off");
    cmd("select.element vertex set 7");
    assert(selV() == [7], format("rig: J-act selection %s", selV()));
    cmd("tool.set move on");
    sideFloor(-1, "J-act");
    cmd("tool.attr move TX 0.4");
    cmd("tool.doApply");
    cmd("tool.set move off");
    immutable double actWant = num(cell("C-activation")["neg_x_vertex_after"].array[0]);
    law(abs(verts()[7][0] - actWant) <= 1e-3,
        format("activation did not latch -X: v7.x %.4f, expected %g", verts()[7][0], actWant));

    // (J11, 7147 P-acen) a press under a PINNED centre does not latch the
    // press side: v7 follows the hand and the side stays the centre's (-X).
    auto pp = cell("C-press-pinned");
    immutable double pinnedHaul = latchRig("move", { cmd("actr.select"); });
    law(pinnedHaul > 0.05, format("a pinned-centre press did not move v7 with the hand: ΔX %.4f, expected > 0 "
                                  ~ "(captured -0.5 -> %.2f)", pinnedHaul, vec(pp["haul"]["after"])[0]));
    dropTool("move");
    sideFloor(-1, "J11");
    dx = readDx();
    law(abs(dx - num(pp["numeric"]["dx"])) <= 1e-3,
        format("a pinned-centre press latched the press side: dx %.4f, expected %+g", dx, num(pp["numeric"]["dx"])));

    // (J12, 7147 S-latch) a selection change while the transform is armed
    // re-activates it, and the activation latches the re-centred handle's side.
    auto ls = cell("C-latch-sel");
    rig();
    selectVerts([7]);
    symmetry(true);
    cmd("tool.set move on");
    settle(300);
    tapKey(KEY_BRACKET_RIGHT);
    assert(selV().length == ls["selection_after_key"]["connected"].array.length,
        format("rig: the connect key selected %s, expected all %d", selV(), ls["selection_after_key"]["connected"].array.length));
    // FLIP PIN, owned by M2 of the tool session model (plan R26 №3): the key
    // door runs `select.connect` as a Model command, whose pre-apply drop
    // (0463) drops the armed transform, so the capture's re-activation has
    // nothing to re-arm here. Green today; it reddens exactly when M2 stops
    // the drop — then turn this back into the law (tool kept; dx -0.4).
    law(toolId() == "", "J12 flip (M2): the connect key no longer drops the armed transform; turn this "
        ~ "block back into the law: tool kept, dx -0.4 (capture C-latch-sel)");
    dropTool("move");

    // (J12m) the same change through the script door, which keeps the tool
    // armed on this tree — isolates the latch from the key's lifecycle.
    rig();
    selectVerts([7]);
    symmetry(true);
    cmd("tool.set move on");
    settle(300);
    selectVerts([0, 1, 2, 3, 4, 5, 6, 7]);
    assert(toolId() == "xfrm", "rig: J12m needs the tool still armed after the script selection");
    dropTool("move");
    sideFloor(1, "J12m");
    dx = readDx();
    law(abs(dx + 0.4) <= 1e-3,
        format("a script selection change while armed did not re-latch: dx %.4f, expected -0.4", dx));
}

void blockV() {
    // Redo of `mesh.transform` replays the side of its first application.
    rig();
    selectVerts([6]);
    symmetry(true);
    sideFloor(-1, "V: fresh session");
    meshTranslate([0.4, 0, 0]);
    immutable double first = verts()[6][0];
    law(abs(first - 0.1) <= 1e-3, format("mesh.transform first application: v6.x %.4f, expected 0.1", first));
    cmd("history.undo");
    assert(near3(verts()[6], V6), "rig: the undo did not restore v6: " ~ fmt(verts()[6]));
    cmd("actr.select");
    sideFloor(1, "V: the selection centre latched +X");
    assert(getJson("/api/history")["redo"].array.length == 1, "rig: the redo stack is not one entry after actr.select");
    cmd("history.redo");
    law(abs(verts()[6][0] - 0.1) <= 1e-3,
        format("mesh.transform redo re-authored on the live side: v6.x %.4f, expected 0.1", verts()[6][0]));
}

void blockE2() {
    // The frame inside the kernel's falloff loop: weight 0.25 (its own), frame -X.
    rig();
    selectVerts([6]);
    symmetry(true);
    toolApply("move", ["TX 0.4"], {
        linearFalloff([-1, 0, 0], [1, 0, 0]);
        cmd("actr.origin");
        sideFloor(-1, "E2: the origin centre latched -X");
    });
    law(abs(verts()[6][0] - 0.4) <= 1e-3,
        format("falloff move authored in the wrong frame: v6.x %.4f, expected 0.4", verts()[6][0]));
}

void blockH4() {
    // Scale through the one-block door, off A: the conjugate of the WHOLE
    // affine (Cj-affine, gap 328), pivot included. v6 alone, fresh session
    // (A = -X), SX 2 about (0.25,0.5,0.5): off A the kernel scales M·p = -0.5
    // about 0.25 → -1.25 and mirrors back → 1.25 (the vertex's own scale
    // would give 0.75). `mesh.transform`'s explicit pivot is ours; the frame
    // rule is the captured one.
    rig();
    selectVerts([6]);
    symmetry(true);
    sideFloor(-1, "H4: fresh session");
    cmd(`{"id":"mesh.transform","params":{"kind":"scale","factor":[2,1,1],"pivot":[0.25,0.5,0.5]}}`);
    auto v = verts();
    law(near3(v[6], [1.25, 0.5, 0.5]) && near3(v[7], V7),
        format("scale off A is not the conjugate: v6 %s v7 %s, expected (1.25,0.5,0.5) / %s",
               fmt(v[6]), fmt(v[7]), fmt(V7)));
}

void blockLayer() {
    // The latch is taken in the LAYER's space (the symmetry plane is
    // layer-local, task 0619). Layer moved +2 in X; v7 (local x -0.5, world
    // x +1.5) alone; the activation places the handle at v7 — local -X — so
    // A = -X and a TX 0.4 moves v7 by its own +0.4. A world-space latch would
    // read +X (world 1.5) and author v7 off A (-0.4).
    rig();
    cmd("layer.attr 0 pos.x 2.0");
    scope(exit) cmd("layer.attr 0 pos.x 0");
    selectVerts([7]);
    symmetry(true);
    cmd("tool.set move on");
    settle(300);
    assert(near3(acenCentre(), [1.5, 0.5, 0.5]), "rig: the handle is not at v7's world position (1.5,0.5,0.5): "
           ~ fmt(acenCentre()));
    sideFloor(-1, "Layer: activation at local -X");
    cmd("tool.set move off");
    immutable double dx = readDx(7);
    law(abs(dx - 0.4) <= 1e-3,
        format("the authoring side was latched in world space on a moved layer: dx %.4f, expected +0.4", dx));
}

void blockK() {
    // A command door does not pair (C-script, S-single).
    rig();
    symmetry(true);
    selectVerts([6]);
    law(selV() == [6], format("a command door paired the selection: %s, expected [6]", selV()));
}

void blockEM() {
    // Element Move with no selection: the picked element's partner takes the
    // mirror on either side (C-elm, Em-mirror). Both y's are compared by sign.
    auto c = cell("C-elm");
    foreach (pick; [V7, V6]) {
        rig();
        symmetry(true);
        cmd("tool.set xfrm.elementMove on");
        cmd("tool.pipe.attr falloff dist 0.044");
        settle(300);
        auto v0 = verts();
        haul(pick, 0, -8, 10);
        auto v = verts();
        cmd("tool.set xfrm.elementMove off");
        immutable double d6 = v[6][1] - v0[6][1], d7 = v[7][1] - v0[7][1];
        law(d6 > 0.1 && d7 > 0.1 && abs(v[6][0] + v[7][0]) <= 1e-3,
            format("element pick on %s did not move the pair: v6 ΔY %.4f v7 ΔY %.4f (captured: both %.2f)",
                   pick[0] < 0 ? "-X" : "+X", d6, d7,
                   vec(c[pick[0] < 0 ? "press_neg_x" : "press_pos_x"]["moved"]["6"]["after"])[1] - 0.5));
        // The pick PLACES the action centre (the picked element), so it
        // latches the authoring side there (W3; P-acen extended to the pick —
        // gap label, Element Move presses were not captured for the latch).
        if (pick[0] > 0) {
            sideFloor(1, "EM: the +X pick latched +X");
            immutable double edx = readDx(7);
            law(abs(edx + 0.4) <= 1e-3,
                format("an element pick on +X did not latch the side: dx %.4f, expected -0.4", edx));
        }
    }
}

unittest {
    indexFloor();
    blockA0();
    blockP();
    blockA();
    blockB();
    blockC();
    blockD();
    blockE();
    blockG();
    blockG2();
    blockU();
    blockH();
    blockH2();
    blockH3();
    blockI();
    blockJ();
    blockV();
    blockE2();
    blockH4();
    blockLayer();
    blockK();
    blockEM();
    cmd("tool.pipe.attr symmetry enabled false");
    lawSummary("test_symmetry_selection_time", 60);
    sideFloorSummary("test_symmetry_selection_time", 31);
}
