// A press away from the Move gizmo drags the selection in EVERY action-centre
// mode — and in the pinned modes it drags it about the PINNED pivot.
//
// What was wrong. One predicate ("may this click relocate the pivot?") was
// answering two questions, the second of which is "may this click start a
// drag?". Only Auto / None / Screen relocate, so in every other mode
// `MoveTool.onMouseButtonDown` returned false on a press outside the gizmo and
// the tool never engaged: no drag, no translation, nothing moved. Half of a
// cross-engine drag corpus was comparing the reference against a stationary
// mesh because of it.
//
// What is pinned here, and why each assertion is discriminating:
//
//   1. ENGAGEMENT. Under Origin / Local / Select / Border a press off every
//      handle plus a drag translates the selection. Fails on the old code with
//      "moved 0.0" — that is the whole defect.
//
//   2. IT IS A TRANSLATION. All selected verts move by ONE delta, and the
//      unselected ones do not move. A drag that engaged but deformed would
//      pass (1) and fail here.
//
//   3. THE ANCHOR IS THE PIVOT, NOT THE PRESS. The screen->world conversion is
//      linearised about one point; in a pinned mode that point is the pivot the
//      stage owns, so the SAME pixel offset from a DIFFERENT press pixel must
//      give the SAME world delta. This is the property the reference legs
//      exhibit — their per-mode translations are predicted from the pivot alone
//      with the press pixel never entering — and it is what would break if the
//      pinned path had been implemented by relocating to the click instead.
//
//   4. THE PIN IS UNTOUCHED. A pinned mode must not acquire a user-placed
//      centre from a drag: after the gesture ACEN still reports its own centre
//      (the world origin under Origin) and userPlaced is still false. This is
//      the half of the old predicate that was CORRECT and had to survive.
//
//   5. AUTO IS UNCHANGED. Auto still anchors on the CLICK, so there the same
//      pixel offset from two different press pixels gives two DIFFERENT deltas.
//      Guards against "fixing" the pinned modes by making every mode pinned.

import std.net.curl;
import std.json;
import std.math  : fabs, sqrt;
import std.conv  : to;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue pj(string p, string b) { return parseJSON(cast(string) post(baseUrl ~ p, b)); }
JSONValue gj(string p)           { return parseJSON(cast(string) get(baseUrl ~ p)); }
void settle()                    { Thread.sleep(150.msecs); }
void cmd(string c)               { pj("/api/command", c); }

Vec3[] verts() {
    Vec3[] outv;
    foreach (v; gj("/api/model")["vertices"].array) {
        auto a = v.array;
        outv ~= Vec3(cast(float) a[0].floating,
                     cast(float) a[1].floating,
                     cast(float) a[2].floating);
    }
    return outv;
}

// The +Y face of the default cube, found by geometry rather than by a magic
// index so a change to the cube's face order cannot silently re-aim the test.
int topFaceIndex() {
    auto model = gj("/api/model");
    auto vs = model["vertices"].array;
    auto polys = ("polygons" in model) ? model["polygons"].array
                                       : model["faces"].array;
    foreach (fi, f; polys) {
        bool allTop = true;
        foreach (iv; f.array)
            if (vs[cast(size_t) iv.integer].array[1].floating < 0.49) { allTop = false; break; }
        if (allTop) return cast(int) fi;
    }
    assert(false, "no +Y face found on the cube");
}

string[string] acenAttrs() {
    foreach (st; gj("/api/toolpipe")["stages"].array) {
        if (st["task"].str == "ACEN") {
            string[string] m;
            foreach (k, v; st["attrs"].object) m[k] = v.str;
            return m;
        }
    }
    assert(false, "no ACEN stage");
}

// Fresh cube, +Y face selected, Move armed, action centre `mode`.
void setup(string mode) {
    pj("/api/reset", "");
    settle();
    pj("/api/select", format(`{"mode":"polygons","indices":[%d]}`, topFaceIndex()));
    cmd("actr." ~ mode);
    cmd("tool.set move");
    settle();
}

// Press at (px,py), drag by (dx,dy), return the per-vertex displacement.
Vec3[] dragFrom(int px, int py, int dx, int dy) {
    auto cam = fetchCamera();
    auto before = verts();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             px, py, px + dx, py + dy, 6));
    settle();
    auto after = verts();
    Vec3[] d;
    foreach (i, a; after) d ~= a - before[i];
    return d;
}

float len(Vec3 v) { return sqrt(v.x*v.x + v.y*v.y + v.z*v.z); }

// The four +Y verts of the default cube, by position — the moving set.
bool isTop(Vec3 v) { return v.y > 0.4f; }

// Two press pixels, both far from every Move handle (the gizmo spans ~90 px
// about the pivot) and both well inside the viewport.
void pressPixels(out int ax, out int ay, out int bx, out int by) {
    auto cam = fetchCamera();
    int cx = cam.width / 2, cy = cam.height / 2;
    ax = cx + 300; ay = cy + 170;
    bx = cx - 320; by = cy - 190;
}

// -------------------------------------------------------------------------
// 1 + 2 — every pinned mode engages, and what it does is a translation.
// -------------------------------------------------------------------------
unittest {
    foreach (mode; ["origin", "local", "select", "border"]) {
        setup(mode);
        auto before = verts();
        int ax, ay, bx, by; pressPixels(ax, ay, bx, by);
        auto d = dragFrom(ax, ay, 120, -60);

        Vec3 first; bool haveFirst = false;
        int movedCount = 0;
        foreach (i, dv; d) {
            if (isTop(before[i])) {
                if (!haveFirst) { first = dv; haveFirst = true; }
                movedCount++;
                assert(fabs(dv.x - first.x) < 1e-3f
                    && fabs(dv.y - first.y) < 1e-3f
                    && fabs(dv.z - first.z) < 1e-3f,
                    format("actr.%s: the moving set must translate by ONE delta; "
                           ~ "vert %d moved (%g,%g,%g) vs (%g,%g,%g)",
                           mode, i, dv.x, dv.y, dv.z, first.x, first.y, first.z));
            } else {
                assert(len(dv) < 1e-3f,
                    format("actr.%s: unselected vert %d moved by %g",
                           mode, i, len(dv)));
            }
        }
        assert(movedCount == 4, format("actr.%s: expected 4 moving verts, got %d",
                                       mode, movedCount));
        assert(len(first) > 0.01f,
            format("actr.%s: a press off the gizmo plus a drag must MOVE the "
                   ~ "selection; it moved %g — the tool never engaged",
                   mode, len(first)));
    }
}

// -------------------------------------------------------------------------
// 3 + 4 — the anchor is the pinned pivot, and the drag does not move the pin.
// -------------------------------------------------------------------------
unittest {
    // Origin is the discriminating mode: its pivot is a fixed world point, so
    // it cannot drift between the two gestures and confound the comparison.
    int ax, ay, bx, by;

    setup("origin");
    pressPixels(ax, ay, bx, by);
    auto dA = dragFrom(ax, ay, 120, -60);

    auto after = acenAttrs();
    assert(after["userPlaced"] == "false",
        "actr.origin: an off-gizmo drag must not place a user pin; got userPlaced="
        ~ after["userPlaced"]);
    foreach (k; ["cenX", "cenY", "cenZ"])
        assert(fabs(after[k].to!float) < 1e-4f,
            format("actr.origin: pivot must stay at the world origin; %s=%s",
                   k, after[k]));

    setup("origin");
    auto dB = dragFrom(bx, by, 120, -60);

    // Any moving vert will do — case 1 already pinned that the whole moving
    // set shares one delta.
    Vec3 a = Vec3(0, 0, 0), b = Vec3(0, 0, 0);
    foreach (i; 0 .. dA.length) if (len(dA[i]) > 1e-6f) { a = dA[i]; break; }
    foreach (i; 0 .. dB.length) if (len(dB[i]) > 1e-6f) { b = dB[i]; break; }

    assert(len(a) > 0.01f && len(b) > 0.01f,
        "both gestures must move the selection");
    assert(fabs(a.x - b.x) < 1e-3f && fabs(a.y - b.y) < 1e-3f
        && fabs(a.z - b.z) < 1e-3f,
        format("actr.origin: the same pixel offset must give the same world "
               ~ "delta from any press pixel (the conversion is linearised at "
               ~ "the PIVOT); got (%g,%g,%g) vs (%g,%g,%g)",
               a.x, a.y, a.z, b.x, b.y, b.z));
}

// -------------------------------------------------------------------------
// 5 — Auto still anchors on the CLICK.
// -------------------------------------------------------------------------
unittest {
    int ax, ay, bx, by;

    setup("auto");
    pressPixels(ax, ay, bx, by);
    auto dA = dragFrom(ax, ay, 120, -60);

    setup("auto");
    auto dB = dragFrom(bx, by, 120, -60);

    Vec3 a = Vec3(0,0,0), b = Vec3(0,0,0);
    foreach (i; 0 .. dA.length) if (len(dA[i]) > 1e-6f) { a = dA[i]; break; }
    foreach (i; 0 .. dB.length) if (len(dB[i]) > 1e-6f) { b = dB[i]; break; }

    assert(len(a) > 0.01f && len(b) > 0.01f,
        "Auto must still drag on a press off the gizmo");
    assert(len(a - b) > 1e-3f,
        format("actr.auto relocates to the CLICK, so two different press "
               ~ "pixels must give different world deltas; got (%g,%g,%g) vs "
               ~ "(%g,%g,%g) — Auto has been turned into a pinned mode",
               a.x, a.y, a.z, b.x, b.y, b.z));
}
