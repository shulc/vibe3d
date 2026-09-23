// Edge Extend — a second press continues the run; under symmetry X the side
// re-latches at every off-handle press, at the press; a handle press keeps it
// (items 12/17; fixture cells `symmetry_second_press_side`,
// `symmetry_handle_press_side`, `symmetry_side_flip_*` of
// tests/fixtures/edge_extend_gesture_laws.json; gaps 211/212/216).
//
// The law "every new press on empty space starts a fresh extend" (gap 174)
// is REFUTED (gap 211): a press on empty space, moving or not, continues the
// same run from its offset, and HTTP reads between gestures do not end it.
// No witness reads the cells `rearm_after_arm_drag`, `rearm_after_haul`,
// `arm_press_after_motionless_click_is_a_new_haul` or
// `switch_key_after_release` as a law.
//
// Continuation is measured against a CONTROL haul of the same five increments
// on a fresh rig, not against d1 * 5/10: the X arm's step is quantised (0.185
// over ten) while the haul's is not (0.182741), so the ratio would miss by
// ~1e-3 for a reason that is our pixel mapping, not the law.
//
// Blocks top to bottom: (k) (c1) (c2) (c3) (f) — green on HEAD; (s-pm) (s-mp)
// (s-c) — the side re-latch, RED on HEAD at (s-pm)'s floor "first off-handle
// press did not latch +X" (HEAD does not reflect at all). The L-latch cell
// (h) of the plan is not built: on this code the handle is drawn at the last
// off-handle press point, so it can never sit on the side opposite the latch
// (recorded in the task card).

import edge_extend_gesture_helpers;
import http_client : getJson, postJson;
import std.algorithm : sort, max;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];
enum int[2][] kMinusRidge = [[0, 1], [1, 2]];

__gshared Offset ctlHaul5;      // (k)
__gshared double oX;            // (s-*) control: two front hauls, no symmetry

unittest { // (k) control: haul (+4,0) x 5 on a fresh rig
    armRig(kPlusRidge, 1.0);
    auto tr = haul(haulPx(), kIncrementPx, 0, 5);
    assert(tr.length == 5 && tr[4].x > 0 && tr[4].y == 0 && tr[4].z == 0,
        "re-press control haul did not extend along X: " ~ tr.to!string);
    ctlHaul5 = tr[4];
    cmd("tool.set edge.extend off");
}

/// (c1)/(c2): haul d1, [motionless click], haul x5 at another point.
void continueCell(bool clickBetween) {
    armRig(kPlusRidge, 1.0);
    haul(haulPx(), kIncrementPx, 0, 10);
    immutable Offset d1 = offset();
    immutable long h0 = undoLen();
    // Measured on HEAD: the live run records nothing, the cleared stack stays empty.
    assert(h0 == 0, "re-press rig: history depth after the first haul is " ~ h0.to!string ~ ", pinned 0");
    if (clickBetween) {
        click(thirdPx());
        assert(vertexCount() == 12 && abs(offset().x - d1.x) <= 1e-6 && abs(offset().y - d1.y) <= 1e-6
            && abs(offset().z - d1.z) <= 1e-6 && undoLen() == h0,
            format("motionless click changed the run (reference absorbs it, gap 211): %d v, offset %s, d1 %s, %d records",
                   vertexCount(), offset(), d1, undoLen() - h0));
    }
    haul(clickPx(), kIncrementPx, 0, 5);
    assert(vertexCount() == 12, "extend re-press started a new ring (reference continues the run, gap 211): "
        ~ vertexCount().to!string ~ " v");
    assert(abs(offset().x - (d1.x + ctlHaul5.x)) <= 1e-4, format("extend re-press did not continue the run's "
        ~ "offset: %s, d1 %s, control %s", offset(), d1, ctlHaul5));
    assert(undoLen() == h0, "extend re-press wrote a history record: " ~ (undoLen() - h0).to!string);
    cmd("tool.set edge.extend off");
}

unittest { // (c1) a second haul continues the run
    continueCell(false);
}

unittest { // (c2) a motionless click between the hauls is absorbed
    continueCell(true);
}

unittest { // (c3) an arm press after a haul continues the run
    armRig(kPlusRidge, 1.0);
    engage();
    immutable Offset e = offset();
    Px p = pressArm(kArmPressPx, 0, 0, "arm press after a haul did not continue the run: x arm press did not grab the arm");
    Px end;
    increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    assert(vertexCount() == 12 && abs(offset().z - e.z) <= 1e-6 && offset().x > 0,
        format("arm press after a haul did not continue the run: %d v, offset %s, after engage %s",
               vertexCount(), offset(), e));
    cmd("tool.set edge.extend off");
}

// --- (f) item 17: re-press under symmetry, two cameras ----------------------

double[3][] allVertices() {
    auto m = model();
    double[3][] out_;
    foreach (i; 0 .. m["vertices"].array.length) out_ ~= vtx(m, i);
    return out_;
}

void rePressUnderSymmetry(bool perspective, Px delegate(bool second) at, string cam) {
    armRig(kPlusRidge ~ kMinusRidge, 0.0, true);
    if (perspective) {
        cmd("viewport.view Perspective");
        auto r = postJson("/api/camera", `{"azimuth":0.5,"elevation":0.4,"distance":3.0,"focus":{"x":0,"y":0,"z":0}}`);
        assert(r["status"].str == "ok", "camera failed: " ~ r.toString);
        assert(getJson("/api/camera")["projKind"].str == "Perspective", "rig: the camera is not perspective" ~ cam);
    }
    haul(at(false), kIncrementPx, 0, 10);
    assert(pressAnchor()[0] < -0.05, "rig: the first press was not on the -X side" ~ cam ~ ": " ~ pressAnchor().to!string);
    immutable size_t v0 = vertexCount();
    auto before = allVertices();
    Px p = at(true);
    press(p);
    assert(moveOffGizmo() && pressAnchor()[0] < -0.05,
        "rig: the second press was not an off-handle press on the -X side" ~ cam ~ ": " ~ pressAnchor().to!string);
    auto atPress = allVertices();
    assert(atPress.length == before.length, "extend re-press under symmetry moved the mesh at the press (same side)" ~ cam);
    foreach (i; 0 .. before.length)
        foreach (k; 0 .. 3)
            assert(abs(atPress[i][k] - before[i][k]) <= 1e-6,
                format("extend re-press under symmetry moved the mesh at the press (same side)%s: vertex %d %s -> %s",
                       cam, i, before[i], atPress[i]));
    // Per increment: the largest displacement of the outermost ring.
    double[] d;
    auto prev = atPress;
    foreach (i; 0 .. 10) {
        p = Px(p.x + kIncrementPx, p.y);
        motion(p, kIncrementPx, 0);
        auto cur = allVertices();
        double m = 0;
        foreach (j; 9 .. cur.length)
            foreach (k; 0 .. 3) m = max(m, abs(cur[j][k] - prev[j][k]));
        d ~= m;
        prev = cur;
    }
    release(p);
    assert(d.length == 10, "re-press under symmetry: read " ~ d.length.to!string ~ " states" ~ cam);
    auto rest = d[1 .. $].dup;
    rest.sort();
    immutable double median = rest[4];
    assert(d[0] <= 1.5 * median, format("extend re-press under symmetry jumped on the first increment%s: d %s", cam, d));
    assert(vertexCount() == v0, format("extend re-press under symmetry started a new ring%s: %d -> %d v",
                                      cam, v0, vertexCount()));
    cmd("tool.set edge.extend off");
}

unittest { // (f) item 17: orthographic top
    rePressUnderSymmetry(false, (bool second) => second ? topScreen(-0.6, -0.5) : topScreen(-0.4, 0.5), " (top)");
}

unittest { // (f) item 17: perspective
    rePressUnderSymmetry(true, (bool second) {
        auto c = viewCentre();
        return second ? Px(c.x - 250, c.y - 120) : Px(c.x - 200, c.y + 120);
    }, " (perspective)");
}

// --- the side re-latch (C2-sym-sel rig, front camera) -----------------------

/// Under symmetry: the four new vertices at x = +-want.
void assertRidges(double want, string msg) {
    auto nv = newVertices();
    size_t plus = 0, minus = 0;
    foreach (v; nv) {
        if (abs(v[0] - want) <= 1e-4) ++plus;
        else if (abs(v[0] + want) <= 1e-4) ++minus;
    }
    assert(nv.length == 4 && plus == 2 && minus == 2, format("%s: new vertices %s, expected x = +-%s", msg, nv, want));
}

/// Control: the same two front hauls with no symmetry; oX = their sum.
void frontControl() {
    rigNoArm([[7, 8]], true, 0.25, 0.55);
    keyArm();
    frontHaul(0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    frontHaul(-0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    oX = offset().x;
    assert(oX > 0.1, "re-latch control: two hauls reached " ~ oX.to!string);
    cmd("tool.set edge.extend off");
}

void relatchCell(double firstX, double secondX, string order) {
    frontControl();
    symSelRig();
    keyArm();
    frontHaul(firstX, 1.35, kIncrementPx, kIncrementPx, 10);
    immutable double o1 = offset().x;
    if (firstX > 0) {
        assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side");
        assertRidges(1 + o1, "first off-handle press did not latch +X");
    } else {
        assert(pressAnchor()[0] < -0.05, "rig: the first press was not on the -X side");
        assertRidges(1 - o1, "first off-handle press did not latch -X");
    }
    frontHaul(secondX, 1.35, kIncrementPx, kIncrementPx, 10);
    assert(secondX < 0 ? pressAnchor()[0] < -0.05 : pressAnchor()[0] > 0.05,
        "rig: the second press was not on the other side: " ~ pressAnchor().to!string);
    assert(vertexCount() == 13, "extend under symmetry: the second press: " ~ vertexCount().to!string ~ " v");
    if (secondX < 0)
        assertRidges(1 - oX, "extend under symmetry: the second press did not re-latch the side (" ~ order ~ ": inward)");
    else
        assertRidges(1 + oX, "extend under symmetry: the second press did not re-latch the side (" ~ order ~ ": outward)");
    cmd("tool.set edge.extend off");
}

unittest { // (s-pm) +X then -X: inward — the red line on HEAD (its first floor)
    relatchCell(0.5, -0.5, "+X then -X");
}

unittest { // (s-mp) -X then +X: outward
    relatchCell(-0.5, 0.5, "-X then +X");
}

unittest { // (s-c) a motionless press on the other side flips at the press
    symSelRig();
    keyArm();
    frontHaul(0.5, 1.35, kIncrementPx, kIncrementPx, 10);
    immutable double o1 = offset().x;
    assert(pressAnchor()[0] > 0.05, "rig: the first press was not on the +X side");
    assertRidges(1 + o1, "first off-handle press did not latch +X");
    Px m = frontScreen(-0.5, 1.35);
    press(m);
    assert(pressAnchor()[0] < -0.05, "rig: the click was not on the -X side: " ~ pressAnchor().to!string);
    release(m);
    auto preview = newVertices();
    assertRidges(1 - o1, "a motionless press on the other side did not flip the side at the press (reference "
        ~ "flips at the press and keeps it, gap 216)");
    cmd("tool.set edge.extend off");
    settle(250);
    auto committed = newVertices();
    assert(committed.length == preview.length, "committed extend differs from the preview after a side re-latch");
    foreach (i; 0 .. preview.length)
        foreach (k; 0 .. 3)
            assert(abs(committed[i][k] - preview[i][k]) <= 1e-6,
                format("committed extend differs from the preview after a side re-latch: %s vs %s", committed, preview));
}
