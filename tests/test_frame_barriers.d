// Card test-sleep-removal: the two frame barriers every suite driver now uses
// in place of fixed sleeps (tests/http_client.d `waitPlaybackProcessed` and
// `frameFence`).
//
// Why a scripted transport for the first two cells. Over HTTP the barriers are
// nearly always satisfied for free: a request sent after an answer is usually
// served in a LATER tickAll pass, so deleting either wait leaves every suite
// cell green (measured: with `frameFence` returning at once, test_change_bus
// stayed green). The pass logic the helpers add is therefore witnessed here,
// against a status sequence that separates "returned at once" and "returned on
// the first read that satisfies the wrong comparison" from the real rule. The
// server half, `processed` itself, is witnessed against the production
// HttpServer by tests/unit/playback_owner_test.d U9. The live cell at the end
// is a population floor for the real route.

import http_client : ClientResponse, clearInProcessTransport, getJson,
    postJson, setInProcessTransport, frameFence, waitPlaybackProcessed;
import std.format : format;
import std.json : JSONType;

void main() {}

// Replays `bodies` for GET /api/play-events/status, counting reads.
private size_t scriptStatus(string[] bodies, void delegate() run) {
    size_t reads;
    setInProcessTransport((string method, string path, string body_) {
        assert(method == "GET" && path == "/api/play-events/status",
            "barrier helper sent an unexpected request: " ~ method ~ " " ~ path);
        assert(reads < bodies.length,
            format("barrier helper read past the script (%d reads)", reads));
        return ClientResponse(200, bodies[reads++]);
    });
    scope(exit) clearInProcessTransport();
    run();
    return reads;
}

private string st(bool finished, bool processed, long frame) {
    return format(`{"finished":%s,"processed":%s,"frame":%d}`,
        finished, processed, frame);
}

unittest { // B1: frameFence returns on the first read of a LATER pass
    auto reads = scriptStatus([st(true, true, 10), st(true, true, 10),
        st(true, true, 10), st(true, true, 11), st(true, true, 12)],
        () { frameFence(); });
    assert(reads == 4, format("B1 frameFence(1) must stop at the first read "
        ~ "served in pass start+1; it made %d reads (expected 4)", reads));

    reads = scriptStatus([st(true, true, 5), st(true, true, 6),
        st(true, true, 6), st(true, true, 7), st(true, true, 8)],
        () { frameFence(null, 2); });
    assert(reads == 4, format("B1 frameFence(2) must wait two passes; "
        ~ "%d reads (expected 4)", reads));
}

unittest { // B2: waitPlaybackProcessed ignores `finished` and waits for `processed`
    auto reads = scriptStatus([st(false, false, 3), st(true, false, 4),
        st(true, false, 4), st(true, true, 5), st(true, true, 6)],
        () { waitPlaybackProcessed(); });
    assert(reads == 4, format("B2 waitPlaybackProcessed must return on the first "
        ~ "processed read; %d reads (expected 4)", reads));
}

unittest { // B3: the live route reports the barrier (population floor)
    postJson("/api/command", `{"id":"scene.reset"}`);
    // A log whose only event is due 150 ms after acceptance: the read right
    // after the POST must see it pending, or the wait below proves nothing.
    auto r = postJson("/api/play-events",
        `{"t":150,"type":"SDL_MOUSEMOTION","x":5,"y":5,"xrel":0,"yrel":0,"state":0,"mod":0}`);
    assert(r["status"].str == "success", "B3 play-events refused: " ~ r.toString);
    auto pending = getJson("/api/play-events/status");
    assert(pending["processed"].type == JSONType.false_,
        "B3 an undelivered log read processed: " ~ pending.toString);
    immutable f0 = pending["frame"].integer;
    waitPlaybackProcessed();
    auto done = getJson("/api/play-events/status");
    assert(done["finished"].type == JSONType.true_
        && done["processed"].type == JSONType.true_
        && done["frame"].integer > f0,
        "B3 processed did not hold after the wait: " ~ done.toString);
    immutable f1 = done["frame"].integer;
    frameFence();
    assert(getJson("/api/play-events/status")["frame"].integer > f1,
        "B3 frame did not advance across a fence");
}
