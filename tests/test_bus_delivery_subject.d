// Task 1906 stage 0, review B1 — THE SYNCHRONOUS DELIVERY ONLY EVER NAMES A
// MESH THE DOCUMENT OWNS.
//
// `Mesh` is a plain struct, so before the fix `commitChange` on ANY instance
// reached every listener. Measured on this tree:
//
//   MeshSnapshot.restore on the edge-bevel preview's private `cage_`
//     (first line of tools/edit/preview_rebuild.d :: PreviewRebuild.run,
//      called once per mouse-motion frame from the bevel drag handler)
//                                                       →      1 delivery, 0x3f
//   makeCube()            (one commit per addFace)      →      6 deliveries
//   makeGridPlane(316)                                  → 99 856 deliveries
//
// app.d's hub ORs whatever it is handed into `meshChangedFlags`, whose
// `Geometry` arm runs `syncSelection` on the LIVE document mesh — so an
// unfiltered delivery lets a private scratch mesh drive it. That is the 1620 flicker class, arriving through the bus.
//
// The fix is a filter consulted at the top of `Mesh.deliverPending`:
// `mesh.g_isDocumentMesh`, installed by app.d as `document.ownsMesh` (true iff
// some Layer's mesh field is at that address). This file is its BEHAVIOURAL
// witness, on the live editor, where the scratch meshes are real ones rather
// than a test's own.
//
// WHY THESE TWO CASES AND NOT OTHERS. They are the two shapes the defect takes:
//
//   * `/api/reset` is the WHOLESALE-ASSIGNMENT shape (`*mesh = makeCube()` in
//     commands/scene/reset.d). The six commits happen on a stack-local Mesh
//     that is then copied into the layer. It is also the S2 dangling-pointer
//     case: `SceneReset` overrides `apply()`, so it opens no delivery batch and
//     the temp would have been delivered outright — but a sibling that DOES
//     batch would have put that stack address into the deferred set and read it
//     after the frame died.
//   * the bevel preview drag is the LONG-LIVED-PRIVATE-MESH shape: `cage_`
//     belongs to the tool, not to any layer, and it is restored once per motion
//     frame for the whole gesture.
//
// MUTATION (plan §Мутация, row `0-B1`): delete
// `if (!deliverySubjectAccepted(&this)) return;` from `Mesh.deliverPending`.
// Both `unittest` blocks below redden, and the record of what they printed is
// in the card.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.format : format;
import std.math   : fabs, sqrt;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void settle() { Thread.sleep(130.msecs); }

void play(string log) { playAndWait(log, BASE); settle(); }

string motion(double t, int x, int y, int state = 1) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  t, x, y, state);
}

string button(string kind, double t, int x, int y) {
    return format(`{"t":%.3f,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, kind, x, y);
}

long deliveries() { return getJson("/api/changes")["deliveryCount"].integer; }

JSONValue model() { return getJson("/api/model"); }

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer, y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

void selectTopFrontEdge() {
    auto m = model();
    int ei = edgeIndex(m, 6, 7);
    assert(ei >= 0, "cube top-front edge missing");
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`)));
    assert(r["status"].str == "ok", "edge selection failed");
}

struct DragSetup { int x0, y0, x1, y1; }

// Lifted from tests/test_edge_bevel_tool.d :: armHandle — same handle, same
// frozen axis, so the gesture this file measures is the one that file already
// proves behaves correctly.
DragSetup armHandle() {
    cmd("tool.set edge.bevel on");
    settle();

    double sx, sy;
    bool found;
    fetchHandlePart(0, sx, sy, found, BASE);
    assert(found, "edge-bevel Width part 0 missing from /api/tool/handles");

    int x0 = cast(int)sx, y0 = cast(int)sy;
    play(motion(0.0, x0, y0, 0) ~ "\n" ~ motion(0.03, x0, y0, 0));

    auto cam = fetchCamera(BASE);
    auto vp  = viewportFromCamera(cam);
    Vec3 anchor = Vec3(0.0f, 0.5f, 0.5f);
    Vec3 axis   = normalize(Vec3(0.0f, 1.0f, 1.0f));
    float ax, ay, bx, by;
    assert(projectToWindow(anchor, vp, ax, ay), "bevel anchor projects off camera");
    assert(projectToWindow(anchor + axis, vp, bx, by), "bevel width axis projects off camera");
    double dx = bx - ax, dy = by - ay;
    double d = sqrt(dx*dx + dy*dy);
    assert(d > 1.0, "bevel width axis too short on screen");
    return DragSetup(x0, y0,
        x0 + cast(int)(120.0 * dx / d), y0 + cast(int)(120.0 * dy / d));
}

// --------------------------------------------------------------------------
// (1) /api/reset delivers ONCE — for the layer's mesh, not once per face of
//     the cube being built beside it.
//
//     Measured: delta 1, `lastDeliveryFlags` 63 = `MeshChangeAll`.
//     Unfiltered the DELTA is 7: `makeCube()` commits once per `addFace`, six
//     times, on a stack-local `Mesh`, and the document mesh then delivers once
//     more.
//
//     WHAT 63 IS, AND WHY IT WAS 14 BEFORE STAGE 0b. `SceneReset` is an
//     override-`applyImpl` command — not an `Operator` — so before the
//     `final Command.apply()` wrapper it ran inside NO delivery batch, and its
//     one delivery fired mid-command, at `mesh.resetSelection()`'s own
//     `commitChange(Geometry | Marks)` = 14. The `mesh.noteChange(MeshChangeAll)`
//     the command makes three statements later — its way of saying "every class
//     on this mesh is new, the counters were reset by `*mesh = …`" — was
//     ORPHANED by that: `noteChange` never delivers, so those bits rode
//     whatever unrelated publisher committed next.
//
//     Under the wrapper the whole command is one delivery batch, so the single
//     delivery at its close carries the UNION — `resetSelection`'s classes plus
//     the `MeshChangeAll` note that names them all. That is the coalescing law,
//     and it is also the reason this assert is EXACT rather than a mask: it is
//     the suite-level red for mutation `0-ANCHOR`. Delete
//     `beginDeliveryBatchGlobal()` from the wrapper (or make `apply()`
//     non-`final` again) and this word drops back to 14 on a REAL command —
//     the unit-level red is `tests/unit/command_apply_anchor_test.d`, over a
//     test double that can do what no shipped command does today and
//     loop-commit.
//
//     WHAT IT DOES NOT WITNESS. Not the "`deliverPending` rejects WITHOUT
//     clearing `undelivered*_`" rule — an earlier revision of this comment
//     claimed it and was measured wrong: the reviewer rewrote the rejection arm
//     to zero `undeliveredChanges_` / `undeliveredSelDomains_` and the assert
//     stayed GREEN, because `makeCube()`'s scratch commits are `Geometry`
//     (Points|Polygons = 6), a strict SUBSET of what this path re-commits one
//     line later. Every primitive `/api/reset` can build is the same shape, so
//     no reset arm can separate the two rules. The carry rule is witnessed
//     where it can actually fail: block (i) of `tests/unit/change_bus_test.d`,
//     which commits a class NO document-mesh publisher re-commits (`Maps`) on a
//     REJECTED scratch mesh, assigns the scratch over the document mesh, and
//     reads that class back out of the next document delivery.
// --------------------------------------------------------------------------
unittest {
    // Two resets, and the SECOND is the measurement. The first normalises the
    // process out of whatever the previous test in this worker left behind
    // (tool armed, selection, a dirty document), so the delta below is a
    // property of `scene.reset` and not of the state it happened to start in.
    auto warm = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset", `{"type":"cube"}`)));
    assert(warm["status"].str == "ok", "cube reset failed");
    settle();

    const long before = deliveries();
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset", `{"type":"cube"}`)));
    assert(r["status"].str == "ok", "cube reset failed");
    settle();
    const long delta = deliveries() - before;

    assert(delta == 1,
        format("scene.reset must deliver EXACTLY ONCE, for the layer's own "
             ~ "mesh; got %d. Six of the seven an unfiltered build produces "
             ~ "come from makeCube()'s per-addFace commits on a stack-local "
             ~ "Mesh no Layer owns", delta));

    // 63 = `change_bus.MeshChangeAll` — the UNION of everything `scene.reset`
    // published inside its one delivery batch. Asserted EXACTLY, not as a mask:
    // 14 is the pre-stage-0b value (the mid-command delivery, with the
    // command's own `noteChange(MeshChangeAll)` orphaned), so an equality here
    // reddens if the wrapper stops batching. See the block comment above.
    const long flags = getJson("/api/changes")["lastDeliveryFlags"].integer;
    assert(flags == 63,
        format("the one delivery must carry the UNION of the whole command — "
             ~ "MeshChangeAll = 63. A 14 means the delivery fired mid-command "
             ~ "at resetSelection's commitChange and the trailing "
             ~ "noteChange(MeshChangeAll) was orphaned, i.e. Command.apply's "
             ~ "final wrapper opened no delivery batch; got %d", flags));
}

// --------------------------------------------------------------------------
// (2) An edge-bevel preview drag delivers only for the document mesh.
//
//     Measured, 6 motion frames after the press:
//
//       frame 1   9 deliveries, last flags 14  — the preview's first build
//                                                 (topology: the bevel's new
//                                                 vertices and faces)
//       frames 2-6  1 delivery each, flags 1   — steady state: Position only
//
//     STEADY STATE IS THE DISCRIMINATOR, and one per frame is the whole claim.
//     `PreviewRebuild.run` opens with `MeshSnapshot.restore` on the tool's
//     private `cage_` on EVERY frame, and rebuilds through scratch meshes no
//     Layer owns. Measured on the unfiltered build: TEN deliveries per steady
//     frame instead of one, every one of the extra nine landing in app.d's hub
//     and its Geometry arm's syncSelection. The first frame is not pinned to a
//     number: its count is the preview build's own commit granularity, which
//     this task neither owns nor changes.
// --------------------------------------------------------------------------
unittest {
    auto reset = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("scene.reset", `{"type":"cube"}`)));
    assert(reset["status"].str == "ok", "cube reset failed");
    selectTopFrontEdge();
    const size_t cubeVerts = model()["vertices"].array.length;
    assert(cubeVerts == 8, "fixture: a bevel drag on the stock cube");

    auto d = armHandle();
    play(button("SDL_MOUSEBUTTONDOWN", 0.0, d.x0, d.y0));
    assert(getJson("/api/tool/state")["dragPart"].integer == 0,
        "Width handle did not capture on mouse-down — with no capture the "
      ~ "motions below move the camera and the preview never rebuilds, which "
      ~ "would make every delivery count below trivially right");

    enum int kMotions = 6;
    long prev = deliveries();
    long firstFrame = 0;
    foreach (i; 1 .. kMotions + 1) {
        int x = d.x0 + (d.x1 - d.x0) * i / kMotions;
        int y = d.y0 + (d.y1 - d.y0) * i / kMotions;
        play(motion(0.0, x, y));
        const long now   = deliveries();
        const long frame = now - prev;
        prev = now;

        if (i == 1) {
            firstFrame = frame;
            assert(frame > 0,
                "the first motion frame must build the preview — zero "
              ~ "deliveries here means the drag never reached the tool");
            continue;
        }

        assert(frame == 1,
            format("steady-state motion frame %d delivered %d times, not 1. "
                 ~ "PreviewRebuild.run restores the tool's private `cage_` on "
                 ~ "every frame and rebuilds through scratch meshes; any extra "
                 ~ "delivery here is one of those reaching app.d's hub "
                 ~ "(measured unfiltered: 10)", i, frame));
        const long flags = getJson("/api/changes")["lastDeliveryFlags"].integer;
        assert(flags == 1,
            format("steady-state frame %d delivered flags %d, not Position "
                 ~ "(1) — 63 (0x3f) is what a cage_ restore publishes",
                   i, flags));
    }

    // The behaviour half: the same drag still works, so the count above is a
    // count of a WORKING preview and not of a drag that quietly stopped
    // rebuilding. `built` and the vertex growth are what app.d's hub drives
    // off `meshChangedFlags`; if the filter had rejected the document mesh
    // too, these would be the assertions that said so.
    auto st = getJson("/api/tool/state");
    assert(st["built"].type == JSONType.true_,
        "the drag left no built preview — the delivery counts above would be "
      ~ "measuring nothing");
    assert(st["width"].floating > 1e-3,
        "the drag produced no width");
    assert(model()["vertices"].array.length > cubeVerts,
        "the preview added no geometry to the document mesh");

    import std.stdio : writeln;
    writeln("[bus delivery] first preview frame = ", firstFrame,
            " deliveries; steady state = 1/frame across ",
            kMotions - 1, " frames");

    play(button("SDL_MOUSEBUTTONUP", 0.0, d.x1, d.y1));
    cmd("tool.set edge.bevel off");
}
