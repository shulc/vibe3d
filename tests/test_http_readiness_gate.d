// test_http_readiness_gate — task 1740.
//
// WHAT THIS PINS, AND WHY IT CANNOT BE PINNED FROM AN ORDINARY SUITE TEST.
// Every other test in this directory runs against a vibe3d the runner has
// already waited for, so the state under test here — the interval between
// "the port is open" and "the app is wired" — is over before those tests get
// a chance to look at it. This one therefore launches its OWN instance on a
// free port and starts sampling BEFORE the process exists.
//
// The defect, measured on 2026-08-30 before the gate was added (`--test`,
// plain `dub build`, 32-core host, raw sockets with no pause):
//
//   POST /api/command  1058 replies of {"status":"error",
//                      "message":"command handler not set"}  over 258->460 ms
//   GET  /api/camera   1196 replies of 500                   over 258->493 ms
//
// and with four instances pinned to four cores under llvmpipe, 1504-2065
// replies over ~1.5 s. So the window is a property of the ORDER in app.d
// (`start()` at :1171, `wireHttpProviders` at :4892) and reproduces on any
// host — it needs neither a sanitizer build nor a slow one.
//
// Both of those answers were INVISIBLE to a caller that did not parse the
// body: one was a 200, the other a 500 that also means "this provider is
// genuinely absent". The nightly that this cost (task 1410) waited on
// /api/registry — which is served from a static table and answers throughout
// the whole window — decided the instance was up, fired one command into the
// gap and lost the night on a perfectly healthy process.
//
// THE THREE CELLS, and WHICH MUTATION EACH ONE ANSWERS TO — measured, not
// asserted. Both mutations below were run and the named cell was watched go
// red; the wording matters because the two cells do NOT cover the same code:
//   1. /api/command answers 503 at least once before the app is wired, and
//      never the old `command handler not set` body.
//      Reddens on a FULL revert (gate removed AND the route's null-handler
//      arm restored to its 200):
//        AssertError@…(251) 1740 cell 1: /api/command must answer 503 …
//        Timeline: 200=1 connect-refused=412 | firstOk=449ms
//        | bodies: ["{\"status\":\"error\",\"message\":\"command handler not set\"}"]
//      It does NOT redden on the gate alone, because the route's own arm now
//      answers 503 as well — deliberate (one shape on the wire), and the
//      reason cell 2 exists.
//   2. /api/registry — the endpoint that produced the false ready — is gated
//      too. This is the cell that pins the GATE ITSELF. Reddens on removing
//      only the `handleRequest` gate:
//        AssertError@…(283) 1740 cell 2: /api/registry answers from a STATIC
//        table … Timeline: 200=1 connect-refused=415 | firstOk=452ms
//        | bodies: ["{\"commands\":[],\"tools\":[]}"]
//      Read that body: 200, at 452 ms, with an EMPTY command list — the
//      registry answering before `registerCommands()` has populated it is
//      exactly the false ready the nightly took.
//   3. the gate LIFTS, and once lifted the same routes answer normally. A
//      gate wired to "never ready" would pass cells 1 and 2.
//
// Cell 1 asserting "at least one" is not a race: the port opens ~250 ms into
// startup and the wiring completes ~200 ms later, while a sample here costs
// ~1 ms (a deliberate pause — see `sampleUntilReady`), so the narrowest
// window ever measured still holds ~100 samples. The margin GROWS on a
// slower host, because the window is what the load stretches. If this test
// ever fails for lack of a 503, the readiness contract has changed (someone
// moved `start()` below the wiring, say) and that is worth failing over
// rather than skipping.
//
// Raw sockets rather than std.net.curl on purpose: libcurl honours
// `http_proxy` for `http://localhost:PORT` too, and a probe that can be
// diverted to a proxy is a probe that measures the proxy. That is not
// hypothetical — it is what broke CI on 2026-08-30, separately from this
// task.
import std.stdio    : File, stdin, stderr, writeln;
import std.socket   : Socket, TcpSocket, AddressFamily, SocketType,
                      ProtocolType, InternetAddress;
import std.conv     : to;
import std.string   : indexOf, strip;
import std.algorithm: canFind;
import std.format   : format;
import std.process  : spawnProcess, wait, thisProcessID, Pid;
import std.file     : mkdirRecurse, rmdirRecurse, exists, readText;
import std.path     : buildPath;
import std.datetime.stopwatch : StopWatch, AutoStart;

import core.thread            : Thread;
import core.time              : msecs;
import core.sys.posix.signal  : kill, SIGTERM, SIGKILL;

// druntime runs every unittest before main(); the body stays empty like every
// other test in this directory.
void main() {}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

struct Sample {
    string code;    // "503", "200", "connect-refused", "EMPTY-REPLY", "io-error"
    string body_;
}

/// One request, one connection, no library between us and the socket.
Sample probeOnce(ushort port, string method, string path, string reqBody) {
    auto s = new TcpSocket();
    scope(exit) s.close();
    try { s.connect(new InternetAddress("127.0.0.1", port)); }
    catch (Exception) { return Sample("connect-refused", ""); }

    string req = method ~ " " ~ path ~ " HTTP/1.1\r\nHost: localhost\r\n"
               ~ "Connection: close\r\n";
    if (reqBody.length)
        req ~= "Content-Type: application/json\r\nContent-Length: "
             ~ reqBody.length.to!string ~ "\r\n";
    req ~= "\r\n" ~ reqBody;

    try {
        s.send(cast(const(void)[]) req);
        char[8192] buf;
        string resp;
        for (;;) {
            auto n = s.receive(buf[]);
            if (n <= 0) break;
            resp ~= buf[0 .. n].idup;
            if (resp.length > 262144) break;
        }
        if (resp.length == 0) return Sample("EMPTY-REPLY", "");
        auto sp = resp.indexOf(' ');
        string code = (sp >= 0 && resp.length > sp + 4)
                    ? resp[sp + 1 .. sp + 4].idup : "???";
        auto hb = resp.indexOf("\r\n\r\n");
        return Sample(code, hb >= 0 ? resp[hb + 4 .. $].idup : "");
    } catch (Exception) {
        return Sample("io-error", "");
    }
}

/// Hammer one route with no pause until it answers 200 (or the budget runs
/// out), keeping EVERY sample. Keeping the whole timeline rather than the last
/// status is the point: the CI failure this task started from reported one
/// last status and it was not enough to tell three different causes apart.
struct Timeline {
    size_t[string] counts;
    string[]       distinctBodies;
    long           firstOkMs = -1;
    size_t         total;

    void add(Sample s, long atMs) {
        counts[s.code] = counts.get(s.code, 0) + 1;
        total++;
        // Truncated: a failure message has to be readable, and the ready
        // /api/registry body alone is tens of kilobytes.
        if (s.body_.length && distinctBodies.length < 8) {
            auto b = s.body_.length > 160 ? s.body_[0 .. 160] ~ "..." : s.body_;
            if (!distinctBodies.canFind(b)) distinctBodies ~= b;
        }
        if (s.code == "200" && firstOkMs < 0) firstOkMs = atMs;
    }

    size_t at(string code) const { return counts.get(code, 0); }

    string render() const {
        string outp;
        foreach (k, v; counts) outp ~= format("%s=%d ", k, v);
        return outp ~ format("| firstOk=%sms | bodies: %s",
                             firstOkMs, distinctBodies);
    }
}

Timeline sampleUntilReady(ushort port, string method, string path,
                          string reqBody, int budgetMs) {
    Timeline t;
    auto sw = StopWatch(AutoStart.yes);
    while (sw.peek.total!"msecs" < budgetMs) {
        auto s = probeOnce(port, method, path, reqBody);
        t.add(s, sw.peek.total!"msecs");
        if (s.code == "200") break;
        // 1 ms between samples, not zero. The window is 200 ms at its
        // narrowest measured value, so this still takes ~100 samples inside
        // it — two orders of margin on the one-503 assertion — while keeping
        // two hammering threads from contending with the starting app for the
        // log mutex on a four-core CI worker.
        Thread.sleep(1.msecs);
    }
    return t;
}

// ---------------------------------------------------------------------------
// Self-launched instance
// ---------------------------------------------------------------------------

ushort pickFreePort() {
    auto sock = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope(exit) sock.close();
    sock.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) sock.localAddress).port;
}

__gshared ushort g_port;
__gshared string g_scratch;
__gshared string g_logPath;
__gshared Pid    g_pid;

// The two timelines, captured concurrently in the module ctor so both cover
// the SAME startup. Sampling them one after another would measure two
// different boots, and only the first would contain a window at all.
__gshared Timeline g_cmdLine;
__gshared Timeline g_registryLine;

string logTail() {
    try {
        auto txt = readText(g_logPath);
        return txt.length > 4000 ? txt[$ - 4000 .. $] : txt;
    } catch (Exception e) { return "(log unreadable: " ~ e.msg ~ ")"; }
}

// `shared static this`, NOT `static this`: a module-level `static this()`
// runs once per THREAD, and this one spawns a thread. With the per-thread
// form the new thread re-enters this body, spawns another, and the process
// dies of stack exhaustion — SIGSEGV before a single assertion runs, which
// looks exactly like a silent pass when the output is piped.
shared static this() {
    g_port    = pickFreePort();
    g_scratch = buildPath("/tmp", "vibe3d_readiness_gate_"
                                ~ thisProcessID().to!string ~ "_"
                                ~ g_port.to!string);
    mkdirRecurse(g_scratch);
    g_logPath = buildPath(g_scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = g_scratch;

    // The registry sampler runs on its own thread and starts FIRST, so both
    // timelines begin before the process does.
    auto registryThread = new Thread({
        g_registryLine = sampleUntilReady(g_port, "GET", "/api/registry", "", 60_000);
    });
    registryThread.start();

    auto logFile = File(g_logPath, "wb");
    g_pid = spawnProcess(["./vibe3d", "--test", "--http-port", g_port.to!string],
                         stdin, logFile, logFile, env);

    g_cmdLine = sampleUntilReady(g_port, "POST", "/api/command",
        `{"id":"vibe3d.readiness.probe.nonexistent","params":{}}`, 60_000);
    registryThread.join();
}

shared static ~this() {
    if (g_pid is null) return;
    try { kill(g_pid.processID, SIGTERM); } catch (Exception) {}
    bool dead;
    for (int i = 0; i < 20; ++i) {
        Thread.sleep(50.msecs);
        if (kill(g_pid.processID, 0) != 0) { dead = true; break; }
    }
    if (!dead) try { kill(g_pid.processID, SIGKILL); } catch (Exception) {}
    try { wait(g_pid); } catch (Exception) {}
    if (g_scratch.length && exists(g_scratch))
        try { rmdirRecurse(g_scratch); } catch (Exception) {}
}

// ---------------------------------------------------------------------------
// Cell 1 — the not-ready state is signalled by a STATUS CODE, on the route
// that used to hide it in a 200 body.
// ---------------------------------------------------------------------------
unittest {
    assert(g_cmdLine.firstOkMs >= 0,
        "1740 cell 1: the instance never became ready at all — "
        ~ g_cmdLine.render() ~ "\n--- log tail ---\n" ~ logTail());

    assert(g_cmdLine.at("503") >= 1,
        "1740 cell 1: /api/command must answer 503 at least once before the "
        ~ "app is wired. Zero 503s means the readiness gate was never "
        ~ "reached — either it is gone, or `start()` no longer opens the port "
        ~ "ahead of `wireHttpProviders` (which would be a change to the "
        ~ "readiness contract, not a smaller window). Timeline: "
        ~ g_cmdLine.render());

    foreach (b; g_cmdLine.distinctBodies)
        assert(!b.canFind("command handler not set"),
            "1740 cell 1: the pre-wiring answer must not be a 200 carrying "
            ~ "`command handler not set` — that body is what made this state "
            ~ "invisible to every probe that did not parse it, and leaving it "
            ~ "beside the 503 gives callers two readiness signals to disagree "
            ~ "about. Got: " ~ b);

    assert(g_cmdLine.at("EMPTY-REPLY") == 0 && g_cmdLine.at("io-error") == 0,
        "1740 cell 1: every connection the listener accepts must be ANSWERED "
        ~ "throughout startup — an empty reply is the one shape our server "
        ~ "has no state for, and it is how an unrelated transport failure "
        ~ "gets mistaken for this one. Timeline: " ~ g_cmdLine.render());
}

// ---------------------------------------------------------------------------
// Cell 2 — /api/registry is gated too. This is the endpoint whose static
// answer produced the false "ready" that cost the sanitizer nightly a run
// (task 1410), so a gate that skipped it would leave the original defect.
// ---------------------------------------------------------------------------
unittest {
    assert(g_registryLine.firstOkMs >= 0,
        "1740 cell 2: /api/registry never answered 200 — " ~ g_registryLine.render());

    assert(g_registryLine.at("503") >= 1,
        "1740 cell 2: /api/registry answers from a STATIC table, so without "
        ~ "the gate it replies 200 for the whole startup window and \"the "
        ~ "registry answers\" means nothing about readiness. It must be "
        ~ "gated like every other /api/* route. Timeline: "
        ~ g_registryLine.render());

    // The lifted answer must be the REAL registry, not merely a 200: a gate
    // that answered 200-with-an-empty-body once "ready" would satisfy the
    // 503 count above and still tell a caller nothing.
    assert(g_registryLine.distinctBodies.canFind!(b => b.canFind("\"commands\"")),
        "1740 cell 2: once the gate lifts /api/registry must serve the actual "
        ~ "registry. Bodies seen: " ~ g_registryLine.render());

    assert(g_registryLine.at("EMPTY-REPLY") == 0
           && g_registryLine.at("io-error") == 0,
        "1740 cell 2: no unanswered connections during startup. Timeline: "
        ~ g_registryLine.render());
}

// ---------------------------------------------------------------------------
// Cell 3 — the gate LIFTS, and stays lifted. Without this a gate hard-wired
// to "never ready" satisfies cells 1 and 2 and is worse than no gate at all.
// ---------------------------------------------------------------------------
unittest {
    foreach (spec; [["GET",  "/api/registry", ""],
                    ["GET",  "/api/camera",   ""],
                    ["POST", "/api/command",
                     `{"id":"vibe3d.readiness.probe.nonexistent","params":{}}`]]) {
        auto s = probeOnce(g_port, spec[0], spec[1], spec[2]);
        assert(s.code != "503",
            "1740 cell 3: after readiness no /api/* route may answer 503 — "
            ~ spec[0] ~ " " ~ spec[1] ~ " gave " ~ s.code ~ ": " ~ s.body_);
        assert(s.code == "200",
            "1740 cell 3: a ready server must serve " ~ spec[0] ~ " "
            ~ spec[1] ~ " normally, got " ~ s.code ~ ": " ~ s.body_);
    }

    // And the command really dispatches now — the gate lifting must mean the
    // handler is wired AND the main loop is draining bridges, not just that a
    // flag flipped. An unknown id is the read-only way to prove dispatch:
    // nothing runs, and only a live dispatcher can name it.
    auto c = probeOnce(g_port, "POST", "/api/command",
        `{"id":"vibe3d.readiness.probe.nonexistent","params":{}}`);
    assert(c.body_.canFind("unknown command id"),
        "1740 cell 3: readiness must mean a command is actually dispatched — "
        ~ "a 200 whose body is a bridge timeout would mean the gate lifted "
        ~ "before the main loop drained anything. Got: " ~ c.body_);
}
