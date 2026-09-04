// Task 1931 stage 2 — the ONE witness that the change bus's surviving
// selection-channel consumer, `app.d`'s `fboSelEpoch`, is actually alive.
//
// WHY THIS FILE EXISTS. `fboSelEpoch` feeds a `DirtyKey` compare that is
// SKIPPED OUTRIGHT under `--test`
// (`source/app.d`'s `if (testMode) { needRender = testRendersCell(...); }
// else { … the DirtyKey compare … }`), so no suite test could previously see
// it move at all — it had no witness in either lane. Task 1931 gave it a
// per-cell STAMP, `Viewport3D.lastSelEpoch`, written for every cell the
// render loop CONSIDERS (before that `testMode` branch), the same way and at
// the same call site `lastOverlayMode` already is, and reported it on
// `/api/viewport/display` beside `overlayMode`. This file is what proves the
// stamp is wired, not just declared.
//
// SEQUENTIAL HTTP, DIFFERENT FRAMES. `/api/select` and `/api/viewport/display`
// are both `Answered.mainThread` — each HTTP call is bridged to the main
// thread and answered from a SEPARATE tick of the render loop, never the same
// one. So this test is not racing the selection against the read: by the time
// `/api/viewport/display` answers, at least one later frame has already run
// the stamp line.
//
// MUTATION (task 1931 stage 2): delete `++fboSelEpoch;` from the
// `changeBus.onSelectionChanged` registration in `source/app.d` — the counter
// stays at its last value forever, the stamp stays flat, and the positive-arm
// assert below reddens: "a real vertex selection must advance …".
//
// Runner: ./run_test.d test_bus_sel_epoch_stamp

import http_client : testBaseUrl, getJson;
import std.net.curl : get, post;
import std.json;
import std.format  : format;
import std.conv    : to;
import core.thread : Thread;
import core.time   : dur;

void main() {}

alias baseUrl = testBaseUrl;

void postJson(string path, string body_ = "") {
    auto resp = cast(string)post(baseUrl ~ path, body_);
    auto j = parseJSON(resp);
    assert("error" !in j
        && (("status" !in j) || j["status"].str == "ok"
                             || j["status"].str == "success"),
        path ~ " failed: " ~ resp);
}


void settle(int ms = 200) { Thread.sleep(dur!"msecs"(ms)); }

/// The active cell's `Viewport3D.lastSelEpoch`, read off `/api/viewport/display`.
long activeCellSelEpoch() {
    auto j = getJson("/api/viewport/display");
    const int activeId = cast(int)j["activeId"].integer;
    foreach (c; j["cells"].array)
        if (cast(int)c["id"].integer == activeId)
            return c["selEpoch"].integer;
    assert(false, "active cell " ~ activeId.to!string
        ~ " not found in /api/viewport/display's \"cells\"");
}

unittest {
    postJson("/api/reset");
    settle();

    const long e0 = activeCellSelEpoch();

    // A real selection-channel delivery: /api/select drives Mesh.selectVertex,
    // which commits and delivers on the selection channel synchronously
    // (task 1906). The positive control this test exists for.
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    settle();
    const long e1 = activeCellSelEpoch();
    assert(e1 > e0,
        format("a real vertex selection must advance "
             ~ "Viewport3D.lastSelEpoch (via app.d's fboSelEpoch) — got %d "
             ~ "then %d", e0, e1));

    // Reading the dump again, with NOTHING selected in between, must not move
    // it further — the epoch tracks selection-channel DELIVERIES, not polls
    // and not frames.
    const long e2 = activeCellSelEpoch();
    assert(e2 == e1,
        format("polling /api/viewport/display alone must not move the "
             ~ "epoch — got %d then %d", e1, e2));
}
