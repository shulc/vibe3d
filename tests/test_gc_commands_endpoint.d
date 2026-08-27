// GET /api/gc/commands — the per-command GC bracket, in the SUITE lane (task 2070).
//
// WHY THIS TEST EXISTS AT ALL, given `tests/test_frames_endpoint.d` right
// beside it can assert nothing: `/api/frames` is backed by `FrameProbe`,
// which is `version (PerfProbe)` and compiles to no-ops in the `modeling`
// build `run_test.d` makes — so that test can only check the route answers
// JSON. `CommandGcProbe` behind THIS route is deliberately always compiled,
// precisely so the default gate can witness the bracket instead of taking it
// on trust from a `perf` build nobody runs on a normal day.
//
// WHAT IT PINS, and the reason each one is here rather than assumed:
//
//  1. `mainLoopThreadId` is stamped. It is written by app.d at startup and
//     read by nothing else; if that call is dropped the field reads 0 and
//     every thread comparison downstream silently passes (0 is the "not
//     recorded" sentinel and the comparison is skipped).
//  2. A command advances `commands` by EXACTLY one, and the bracket ran on
//     the main loop. `GC.allocatedInCurrentThread` is PER-THREAD, and
//     `/api/command` ARRIVES on the HTTP thread while RUNNING on the main
//     one; a bracket on the wrong side of that reads the HTTP thread's own
//     allocation. Measured, that is 0 BYTES FOR EVERY COMMAND — including
//     one that really allocated 70 MB — because the HTTP thread is parked in
//     `Thread.sleep` for the whole dispatch. Identical, plausible, and
//     wrong, which is why this is checked and not commented.
//  3. The bytes track the WORK. A column that reports a constant is
//     indistinguishable from a working one on any single reading.
import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue gc() { return parseJSON(cast(string)get(baseUrl ~ "/api/gc/commands")); }

void resetGrid(int n) { post(baseUrl ~ format("/api/reset?type=grid&n=%d", n), ""); }

void command(string id) {
    post(baseUrl ~ "/api/command", format(`{"id":"%s","params":{}}`, id));
}

unittest { // the endpoint answers, and app.d actually stamped the main loop
    auto j = gc();
    assert(j.type == JSONType.object,
           "/api/gc/commands must return a JSON object");
    foreach (k; ["commands", "lastAllocBytes", "lastCollections",
                 "lastMaxPauseNs", "lastPauseNs", "lastThreadId",
                 "mainLoopThreadId", "offMainThreadBrackets"])
        assert(k in j, "/api/gc/commands is missing key: " ~ k);

    assert(j["mainLoopThreadId"].integer != 0,
           "mainLoopThreadId is 0 — app.d never called markMainLoopThread(), " ~
           "so every off-main-thread check downstream is disarmed (0 is the " ~
           "'not recorded' sentinel and skips the comparison)");
}

unittest { // reading the probe does not itself count as a command
    // Anti-vacuity for the counter the other blocks lean on: if `commands`
    // advanced on a mere GET, "+1 after a command" would pass without any
    // command running.
    auto a = gc()["commands"].integer;
    auto b = gc()["commands"].integer;
    assert(a == b,
           format("GET /api/gc/commands advanced the bracket count %d -> %d " ~
                  "— the counter is measuring reads, not commands", a, b));
}

unittest { // one command ⇒ exactly one bracket, taken on the main loop
    resetGrid(16);
    auto before = gc();
    command("mesh.subdivide");
    auto after = gc();

    assert(after["commands"].integer == before["commands"].integer + 1,
           format("one command must close exactly one bracket, saw %d -> %d",
                  before["commands"].integer, after["commands"].integer));
    assert(after["lastThreadId"].integer == after["mainLoopThreadId"].integer,
           format("the GC bracket ran on thread %d but the main loop is %d " ~
                  "— GC.allocatedInCurrentThread is PER-THREAD, so this " ~
                  "column is measuring a thread that did not run the command",
                  after["lastThreadId"].integer,
                  after["mainLoopThreadId"].integer));
    assert(after["offMainThreadBrackets"].integer == 0,
           "a bracket was taken off the main loop");
    assert(after["lastAllocBytes"].integer > 0,
           "mesh.subdivide on a 16x16 grid allocated 0 bytes — the bracket " ~
           "is not seeing the command's allocation at all");
}

unittest { // the allocation column tracks the work, not a constant
    // The discriminating pair: the SAME command on two mesh sizes. A column
    // wired to a constant, or to the wrong thread, reads the same for both.
    resetGrid(16);
    auto s0 = gc()["commands"].integer;
    command("mesh.subdivide");
    auto small = gc();
    assert(small["commands"].integer == s0 + 1, "small case fired no bracket");
    immutable long smallBytes = small["lastAllocBytes"].integer;

    resetGrid(48);
    auto b0 = gc()["commands"].integer;
    command("mesh.subdivide");
    auto big = gc();
    assert(big["commands"].integer == b0 + 1, "big case fired no bracket");
    immutable long bigBytes = big["lastAllocBytes"].integer;

    // A 48x48 grid is ~9x the faces of a 16x16 one. Demanding 3x rather than
    // 9x leaves room for fixed per-command overhead without leaving room for
    // "the two are the same number".
    assert(bigBytes > smallBytes * 3,
           format("allocation does not track mesh size: n=16 cost %d B and " ~
                  "n=48 cost %d B (needed > 3x). A column that does not move " ~
                  "with the work is not measuring the work.",
                  smallBytes, bigBytes));
}
