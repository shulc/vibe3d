// Module unittests for `ai3d.job_controller`, moved verbatim out of source/ai3d/job_controller.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai3d.job_controller_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import ai3d.event_queue : Ai3dEventQueue;
import ai3d.job_events : Ai3dEvent, Ai3dEventKind;
import ai3d.stage_artifact : stageArtifact, probeHealthCheck, Ai3dProgress,
    Ai3dStageResult, Ai3dHealthResult, Ai3dDefaultRequestedFaces;
import ai3d.job_controller;

unittest {
    // State machine smoke test — no real network (invalid worker URL means
    // stageArtifact/probeHealthCheck fail fast, offline). Exercises: busy()
    // during start(), single-in-flight rejection, and that both a health
    // probe and a job worker eventually post a terminal-ish event, all
    // drainable and none touching any Document/Mesh (this class holds no
    // such reference at all, by construction).
    auto c = new Ai3dJobController();
    assert(!c.busy());

    auto started = c.start("/nonexistent.png", "http://127.0.0.1:1", 500);
    assert(started);
    assert(c.busy());
    assert(!c.start("/nonexistent.png", "http://127.0.0.1:1", 500),
           "single-in-flight: a second start() must no-op while busy");

    // Wait for the worker to finish (invalid URL fails immediately).
    auto deadline = MonoTime.currTime + 5.seconds;
    while (c.busy() && MonoTime.currTime < deadline)
        Thread.sleep(5.msecs);
    assert(!c.busy(), "worker should finish quickly against an unreachable host");

    bool sawTerminalOrError;
    c.drain((ref const Ai3dEvent e) {
        if (e.kind == Ai3dEventKind.terminal || e.kind == Ai3dEventKind.transportError)
            sawTerminalOrError = true;
    });
    assert(sawTerminalOrError);

    assert(c.join(1_000));
}

unittest {
    // Phase 4 (Risk 4c) precondition: join() must return FALSE within the
    // requested budget when the worker is still busy — this is exactly
    // the signal app.d's shutdown path uses to decide whether to fall
    // into normal teardown or take the abrupt core.stdc.stdlib._Exit(0)
    // path. Never actually calls _Exit here (that would kill the test
    // process) — only proves join()'s own timeout-return contract.
    //
    // A local TCP listener that accepts the connection but never responds
    // keeps stageArtifact's probeHealthCheck GET genuinely in flight (past
    // connect, waiting on a response) until its own
    // Ai3dOperationTimeoutMs backstop fires — a deterministic "worker
    // still busy" window regardless of sandbox networking policy (unlike
    // an actually-unreachable host, which some environments fail
    // instantly with no route rather than a slow connect timeout).
    import std.conv : to;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.socket : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    listener.listen(1);
    const port = (cast(InternetAddress) listener.localAddress).port;
    scope(exit) listener.close();

    auto c = new Ai3dJobController();
    assert(c.start("/nonexistent.png", "http://127.0.0.1:" ~ port.to!string, 500));

    auto sw = StopWatch(AutoStart.yes);
    const joined = c.join(50); // budget far shorter than the 10s operation timeout
    sw.stop();
    assert(!joined, "join() must return false while the worker is still waiting on a response");
    assert(sw.peek.total!"msecs" < 500,
           "join() must return promptly at its OWN budget, not block until the worker finishes");

    // Clean up: let the real operation timeout resolve so no thread leaks
    // past this test (comfortably inside Ai3dClientJoinTimeoutMs=35s).
    assert(c.join(15_000), "worker should finish once its own operation timeout fires");
}
