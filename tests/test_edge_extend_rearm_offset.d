// Edge Extend — a new press on empty space starts a NEW extend at offset 0
// (items 12/17; fixture cells `rearm_after_arm_drag`, `rearm_after_haul` of
// tests/fixtures/edge_extend_gesture_laws.json).
//
// The measured law: every press on empty space commits the current extend
// as ONE history record and starts a new one from zero. (a) A motionless
// click therefore adds a zero-length ring — three vertices coincident with
// the previous ridge — and (b) a following drag moves only that new ring, by
// its own travel, not by the first extend's offset plus its own.
//
// HEAD continues the SAME extend from the accumulated offset instead, so the
// click adds nothing: RED at "extend re-arm differs from the reference:
// vertex count" (12, expected 15).
//
// The (b) expectation comes from a CONTROL haul of the same 5 increments on
// a fresh rig, run first: measured on HEAD, the X arm's per-increment step
// and the haul's differ (0.185 vs 0.1827 over ten), so `d1 * 5/10` would
// mismatch by ~1e-3 for a reason that is our pixel mapping, not the law.
//
// History depth is read from a cleared stack (`armRig`), so the cap cannot
// hide an entry.

import edge_extend_gesture_helpers;
import std.conv : to;
import std.format : format;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];
enum string kMsg = "extend re-arm differs from the reference: ";

__gshared double ctlHaul5;

unittest { // control: haul (+4,0) x 5 on a fresh rig
    armRig(kPlusRidge, 1.0);
    auto tr = haul(haulPx(), kIncrementPx, 0, 5);
    assert(tr.length == 5 && tr[4].x > 0 && tr[4].y == 0 && tr[4].z == 0,
        "re-arm control haul did not extend along X: " ~ tr.to!string);
    ctlHaul5 = tr[4].x;
    cmd("tool.set edge.extend off");
}

void rearmCell(bool d1ByArm, string sfx) {
    armRig(kPlusRidge, 1.0);
    if (d1ByArm) {
        engage();
        Px p = pressArm(kArmPressPx, 0, 0, "re-arm: x arm press did not grab the arm" ~ sfx);
        Px end;
        increments(p, kIncrementPx, kIncrementPx, 10, end);
        release(end);
    } else {
        haul(haulPx(), kIncrementPx, 0, 10);
    }
    immutable Offset d1 = offset();
    auto ridge1 = newVertices();
    // Floor: one live extend, nothing recorded yet.
    assert(vertexCount() == 12 && ridge1.length == 3 && d1.x > 0,
        format("re-arm floor%s: %d vertices, d1 %s", sfx, vertexCount(), d1));
    immutable long h0 = undoLen();
    assert(h0 < 40, "re-arm floor: no history headroom (" ~ h0.to!string ~ ")");

    // (a) a motionless click on empty space.
    Px c = clickPx();
    press(c);
    release(c);
    assert(vertexCount() == 15, kMsg ~ "vertex count" ~ sfx ~ ": " ~ vertexCount().to!string ~ ", expected 15");
    immutable Offset oa = offset();
    assert(oa == Offset(0, 0, 0), kMsg ~ "offset not reset" ~ sfx ~ ": " ~ oa.to!string);
    auto nv = newVertices();
    assert(nv.length == 6, kMsg ~ "new ring not coincident" ~ sfx ~ ": " ~ nv.length.to!string ~ " new vertices");
    size_t coincident = 0;
    foreach (v; nv[3 .. 6])
        foreach (r; ridge1)
            if (abs(v[0] - r[0]) <= 1e-6 && abs(v[1] - r[1]) <= 1e-6 && abs(v[2] - r[2]) <= 1e-6) { ++coincident; break; }
    assert(coincident == 3, format("%snew ring not coincident%s: %s vs ridge %s", kMsg, sfx, nv[3 .. 6], ridge1));
    assert(undoLen() == h0 + 1, kMsg ~ "history depth" ~ sfx ~ ": " ~ (undoLen() - h0).to!string ~ " new records, expected 1");

    // (b) a 5-increment haul on empty space moves only the new ring. Not at
    // the click pixel: the click relocated the gizmo there, and a press on
    // the gizmo's centre is a grab, not a press on empty space.
    haul(haulPx(), kIncrementPx, 0, 5);
    assert(vertexCount() == 18, "extend re-arm: second extend vertex count" ~ sfx ~ ": " ~ vertexCount().to!string);
    immutable Offset ob = offset();
    assert(abs(ob.x - ctlHaul5) <= 1e-4,
        format("extend re-arm: second extend carried the first offset%s: offsetX %s, control %s (d1 %s)",
               sfx, ob.x, ctlHaul5, d1.x));
    auto all = newVertices();
    foreach (i; 6 .. 9)
        assert(abs(all[i][0] - (ridge1[0][0] + ob.x)) <= 1e-4,
            format("extend re-arm: last ridge not offset from the previous one%s: %s", sfx, all[6 .. 9]));
    assert(undoLen() == h0 + 2, "extend re-arm: history depth after (b)" ~ sfx ~ ": "
        ~ (undoLen() - h0).to!string ~ " new records, expected 2");
    cmd("tool.set edge.extend off");
}

unittest { // d1 by the X arm (fixture `rearm_after_arm_drag`) — the red line on HEAD
    rearmCell(true, "");
}

unittest { // d1 by a haul (fixture `rearm_after_haul`)
    rearmCell(false, " (haul)");
}
