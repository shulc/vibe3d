// Topology Pen — the SMOOTH LOOP gesture (Shift+Ctrl+RMB), task 2900.
//
// THE GAP. Of the pen's fifteen gestures, five had no positive HTTP coverage at
// all, and smooth loop was one: it appears in no `tests/test_topopen_*.d` file,
// and its only witness was the white-box unit module
// `tests/unit/tools/edit/topology_pen/gestures_test.d`, which calls the tool's
// methods directly and plays no event. Nothing in the tree checked that a real
// chord reaches `onSmoothLoopRmbDown`.
//
// WHY THIS ONE CANNOT BE PINNED BY A COUNT, and why that matters here. Every
// other pen gesture with coverage changes the topology, so an element count
// witnesses it. Smooth loop does not: measured on this stand it leaves
// 26 vertices / 48 edges / 24 faces exactly as it found them and moves
// POSITIONS — 8 of the 26 vertices, by up to 0.16. So the acceptance
// criterion's "a named element count moving in a named direction" is
// unavailable, and the substitute is named explicitly: a COUNT OF DISPLACED
// VERTICES with a floor, plus the exact record the gesture pushed. A file that
// asserted only "the mesh changed" would be satisfied by any pen gesture that
// happened to fire instead; a file that asserted only counts would be green
// over a smooth that moved nothing at all.
//
// THE STAND IS A SUBDIVIDED CUBE, not the plain one. A smooth needs a ring with
// interior neighbours to average toward; on a bare 8-vertex cube every vertex
// is a corner and the gesture has nothing to relax. `mesh.subdivide` gives
// 26/48/24, which is the smallest stand on which the displacement is real.
//
// `built` IS NOT ON THE WIRE for this tool — `/api/tool/state` publishes it for
// exactly six tools tree-wide (`grep -rn '"built"' source/`), none of them the
// pen.
//
// EVERY CHANNEL HERE FAILS CLOSED: the displacement count, the record name and
// the undo delta are all "this moved", so a frozen `/api/model` or a stopped
// `/api/history` goes RED. The count assertions that pin 26/48/24 UNCHANGED are
// the one shape a dead channel could satisfy for free, and they are asserted
// AFTER the displacement check that proves the channel is live.
//
// Run via: ./run_test.d topopen_smoothloop

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.format : format;
import std.math   : sqrt;

void main() {}

enum uint LCTRL  = 0x0040;   // KMOD_LCTRL
enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT

/// Shift+Ctrl+RMB press-and-release at (px,py), with two hover motions first so
/// the pen's picker has resolved the element under the cursor before the button
/// goes down (the codebase's own `clickAt` idiom).
string smoothLoopAt(double t0, int px, int py) {
    enum uint MOD = LCTRL | LSHIFT;
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%u}`,
                  t0, px, py, MOD) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":%u}`,
                  t0 + 10.0, px, py, MOD) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 20.0, px, py, MOD) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 30.0, px, py, MOD);
}

double[][] vertexPositions() {
    double[][] o;
    foreach (v; getJson("/api/model")["vertices"].array)
        o ~= [v.array[0].floating, v.array[1].floating, v.array[2].floating];
    return o;
}

size_t undoDepth() { return getJson("/api/history")["undo"].array.length; }

string lastUndoCommand() {
    auto u = getJson("/api/history")["undo"].array;
    return u.length ? u[$ - 1]["command"].str : "";
}

unittest { // Shift+Ctrl+RMB on an edge relaxes its loop and records one entry
    // NO PRE-DISARM, DELIBERATELY (task 3130). `/api/reset` cancels and DROPS the
    // active tool BEFORE it replaces the geometry, so a gesture left standing by
    // an earlier stand — or by an earlier RED run of this one — cannot commit
    // into the scene this stand is about to read. The explicit
    // `tool.set <tool> off` that used to stand here (task 2900) was a workaround
    // for the opposite order. Removing it is not tidying: it makes this stand a
    // WITNESS for that guarantee instead of a file that hides its loss.
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));
    cmd("mesh.subdivide");
    cmd("history.clear");

    immutable int v0 = vertexCountLayer(0);
    immutable int e0 = edgeCountLayer(0);
    immutable int f0 = faceCountLayer(0);
    assert(v0 == 26 && e0 == 48 && f0 == 24,
        format("setup: the stand must be the once-subdivided cube (26/48/24), "
             ~ "got %d/%d/%d", v0, e0, f0));

    cmd("tool.set mesh.topoPen on");
    immutable size_t u0 = undoDepth();
    auto before = vertexPositions();

    // The operand edge is read off the MODEL rather than assumed: edge 0's
    // endpoints give a midpoint that is guaranteed to lie on a real edge of
    // this stand, whatever the subdivision's own ordering happens to be.
    auto mdl = getJson("/api/model");
    auto e   = mdl["edges"].array[0].array;
    auto a   = before[cast(size_t) e[0].integer];
    auto b   = before[cast(size_t) e[1].integer];
    Vec3 mid = Vec3(cast(float)((a[0] + b[0]) / 2),
                    cast(float)((a[1] + b[1]) / 2),
                    cast(float)((a[2] + b[2]) / 2));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);
    float px, py;
    assert(projectToWindow(mid, vp, px, py),
        "the operand edge's midpoint projects behind the camera — this framing "
        ~ "cannot drive the gesture at all");

    auto r = postJson("/api/play-events",
        viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
        ~ smoothLoopAt(10.0, cast(int) px, cast(int) py) ~ "\n");
    assert("error" !in r, "/api/play-events failed: " ~ r.toString);
    waitPlayerIdle();

    // THE WITNESS, and it is the one this gesture makes available: how many
    // vertices actually moved, and by how much. A smooth that relaxed nothing
    // leaves this at zero while every count below still reads correctly.
    auto after = vertexPositions();
    assert(after.length == before.length,
        format("the smooth changed the vertex count (%d -> %d) — this gesture "
             ~ "is a POSITION edit and must not add or drop geometry",
               before.length, after.length));
    size_t moved   = 0;
    double maxDisp = 0.0;
    foreach (i, p; before) {
        immutable double dx = p[0] - after[i][0];
        immutable double dy = p[1] - after[i][1];
        immutable double dz = p[2] - after[i][2];
        immutable double d  = sqrt(dx * dx + dy * dy + dz * dz);
        if (d > 1e-6) ++moved;
        if (d > maxDisp) maxDisp = d;
    }
    assert(moved >= 4,
        format("the Shift+Ctrl+RMB smooth loop displaced %d of %d vertices "
             ~ "(largest %.6f), expected at least 4 — measured 8 on this stand. "
             ~ "Zero means the chord resolved no ring and nothing reached "
             ~ "`onSmoothLoopRmbDown`, which is exactly the state no test in "
             ~ "this 48-file set could see before", moved, before.length, maxDisp));
    assert(maxDisp > 1e-3,
        format("the largest displacement was %.9f — a 'smooth' that moves "
             ~ "every vertex by less than a thousandth of a unit has relaxed "
             ~ "nothing that a user could see", maxDisp));

    // Asserted AFTER the displacement check, deliberately: these three are
    // "nothing changed", which a dead `/api/model` satisfies for free. They are
    // only meaningful once the check above has proved the channel is live.
    assert(vertexCountLayer(0) == v0 && edgeCountLayer(0) == e0
        && faceCountLayer(0) == f0,
        format("smooth loop must be a POSITION edit: expected %d/%d/%d "
             ~ "unchanged, got %d/%d/%d", v0, e0, f0,
               vertexCountLayer(0), edgeCountLayer(0), faceCountLayer(0)));

    assert(lastUndoCommand() == "mesh.topoPen_smoothloop",
        "the gesture recorded `" ~ lastUndoCommand() ~ "`, expected "
        ~ "`mesh.topoPen_smoothloop` — this tool has eleven record factories "
        ~ "and another name here means the chord resolved to a different "
        ~ "gesture entirely");
    assert(undoDepth() - u0 == 1,
        format("the gesture recorded %d undo entr(ies), expected exactly 1",
               undoDepth() - u0));

    // The undo puts the loop back where it was, which is what makes the entry a
    // real edit record rather than a bookmark. Compared position by position,
    // because the counts cannot see this gesture at all.
    auto u = postJson("/api/command", commandBody("history.undo"));
    assert(u["status"].str == "ok", "undo must succeed: " ~ u.toString);
    auto restored = vertexPositions();
    assert(restored.length == before.length,
        "undo changed the vertex count");
    double worst = 0.0;
    foreach (i, p; before) {
        immutable double dx = p[0] - restored[i][0];
        immutable double dy = p[1] - restored[i][1];
        immutable double dz = p[2] - restored[i][2];
        immutable double d  = sqrt(dx * dx + dy * dy + dz * dz);
        if (d > worst) worst = d;
    }
    assert(worst < 1e-6,
        format("after one undo the worst vertex is %.9f from where the smooth "
             ~ "found it — the recorded entry does not invert the relaxation "
             ~ "it claims to own", worst));
}
