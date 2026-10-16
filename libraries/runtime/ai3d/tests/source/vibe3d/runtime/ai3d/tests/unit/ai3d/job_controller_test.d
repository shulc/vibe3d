// Module unittests for `ai3d.job_controller`, moved verbatim out of source/ai3d/job_controller.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module vibe3d.runtime.ai3d.tests.unit.ai3d.job_controller_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import vibe3d.runtime.ai3d.ai3d.event_queue : Ai3dEventQueue;
import vibe3d.runtime.ai3d.ai3d.job_events : Ai3dEvent, Ai3dEventKind;
import vibe3d.runtime.ai3d.ai3d.stage_artifact : stageArtifact, probeHealthCheck, Ai3dProgress,
    Ai3dStageResult, Ai3dHealthResult, Ai3dDefaultRequestedFaces;
import vibe3d.runtime.ai3d.ai3d.job_controller;

unittest {
    // Task 20263020: the accepted owned peer holds real health I/O in flight
    // until the single-in-flight assertion; evidence: doc/ci_runner_failures_plan_2026-10-16.md.
    import std.conv : to;
    import std.socket : TcpSocket, InternetAddress, Socket, SocketSet;
    auto listener = new TcpSocket();
    listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    listener.listen(1);
    scope(exit) listener.close();
    const url = "http://127.0.0.1:" ~ (cast(InternetAddress) listener.localAddress).port.to!string;
    auto c = new Ai3dJobController();
    scope(exit) { c.stop(); c.join(15_000); }
    assert(!c.busy());

    auto started = c.start("/nonexistent.png", url, 500);
    assert(started);
    auto ready = new SocketSet();
    ready.add(listener);
    assert(Socket.select(ready, null, null, 5.seconds) == 1,
        "worker must connect to the owned health listener");
    auto peer = listener.accept();
    scope(exit) peer.close();
    assert(c.busy(), "accepted peer must hold worker busy");
    assert(!c.start("/nonexistent.png", url, 500),
           "single-in-flight: a second start() must no-op while busy");

    peer.close();
    // Releasing the owned peer must release the worker.
    auto deadline = MonoTime.currTime + 5.seconds;
    while (c.busy() && MonoTime.currTime < deadline)
        Thread.sleep(5.msecs);
    assert(!c.busy(), "worker should finish after the owned peer closes");

    bool sawTerminalOrError;
    c.drain((ref const Ai3dEvent e) {
        if (e.kind == Ai3dEventKind.terminal || e.kind == Ai3dEventKind.transportError)
            sawTerminalOrError = true;
    });
    assert(sawTerminalOrError, "released worker must enqueue terminal or transport error");

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
    import std.socket : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption, Socket, SocketSet;

    auto listener = new TcpSocket();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    listener.listen(1);
    const port = (cast(InternetAddress) listener.localAddress).port;
    scope(exit) listener.close();

    auto c = new Ai3dJobController();
    scope(exit) { c.stop(); c.join(15_000); }
    assert(c.start("/nonexistent.png", "http://127.0.0.1:" ~ port.to!string, 500));

    // Accept the real health-check connection before timing join. Keeping
    // this peer open makes the worker provably in flight; closing it after
    // the timeout contract is observed releases cleanup immediately.
    auto ready = new SocketSet();
    ready.add(listener);
    assert(Socket.select(ready, null, null, 5.seconds) == 1,
        "join fixture must accept a real health connection within its budget");
    auto peer = listener.accept();
    bool peerClosed;
    void closePeer() { if (!peerClosed) { peerClosed = true; peer.close(); } }
    scope(exit) closePeer();
    assert(c.busy(),
        "join precondition: the worker must remain in flight after the local peer accepts it");

    auto sw = StopWatch(AutoStart.yes);
    const joined = c.join(50); // budget far shorter than the 10s operation timeout
    sw.stop();
    assert(!joined, "join() must return false while the worker is still waiting on a response");
    assert(sw.peek.total!"msecs" < 500,
           "join() must return promptly at its OWN budget, not block until the worker finishes");

    const cleanupStart = MonoTime.currTime;
    closePeer();
    assert(c.join(15_000),
        "worker should finish after the controlled local peer closes");
    assert((MonoTime.currTime - cleanupStart).total!"msecs" < 500,
        "worker cleanup must follow the controlled peer close promptly, not wait for the operation timeout");
}
