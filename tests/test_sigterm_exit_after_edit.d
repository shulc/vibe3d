// test_sigterm_exit_after_edit — a `--test` instance must still die on SIGTERM
// after it has recorded a mesh edit.
//
// THE LAW, and it is a property of OUR code, measured here rather than argued.
// SIGTERM reaches a running editor as SDL_QUIT; the input router turns that
// into an ordinary `file.quit` carrying `fromWindowClose`, and every UI command
// passes the unsaved-work guard. One mesh edit makes the document dirty, so the
// guard's verdict becomes `prompt` — and under `--test` the modal is
// SUPPRESSED while the action is still HELD. Nobody can answer a suppressed
// prompt, so the quit was held forever and the process outlived its own kill.
// The window-close route is the harness's only shutdown signal, so a question
// asked there in `--test` turns every kill into a hang.
//
// WHY IT CANNOT BE PINNED FROM AN ORDINARY SUITE TEST: a worker shares ONE
// instance across its whole slice, and this test has to signal an instance to
// death. So it launches its own, twice, on its own free ports.
//
// THE DISCRIMINATING PAIR, and a single instance is not one. An instance that
// recorded NO edit exits on SIGTERM whether the guard defers or not — the
// document is clean, the verdict is `proceed`, and every candidate rule agrees.
// The cells below are therefore run as a pair over instances that differ in
// exactly one request, and the control is asserted ABOVE the edited one so a
// single run buys both halves: druntime stops the module at the first failed
// assert, so everything above a red line is known to have run and passed.
import std.stdio    : File, stdin, stderr;
import std.socket   : Socket, TcpSocket, AddressFamily, SocketType,
                      ProtocolType, InternetAddress;
import std.conv     : to;
import std.string   : indexOf;
import std.algorithm: canFind;
import std.format   : format;
import std.process  : spawnProcess, wait, tryWait, thisProcessID, Pid;
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
// Transport: raw sockets, no library between us and the socket. std.net.curl
// honours `http_proxy` for `http://localhost:PORT` too, and a probe that can be
// diverted to a proxy is a probe that measures the proxy.
// ---------------------------------------------------------------------------

struct Reply {
    string code;    // "200", "503", "connect-refused", "EMPTY-REPLY", "io-error"
    string body_;
}

Reply once(ushort port, string method, string path, string reqBody) {
    auto s = new TcpSocket();
    scope(exit) s.close();
    try { s.connect(new InternetAddress("127.0.0.1", port)); }
    catch (Exception) { return Reply("connect-refused", ""); }

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
        if (resp.length == 0) return Reply("EMPTY-REPLY", "");
        auto sp = resp.indexOf(' ');
        string code = (sp >= 0 && resp.length > sp + 4)
                    ? resp[sp + 1 .. sp + 4].idup : "???";
        auto hb = resp.indexOf("\r\n\r\n");
        return Reply(code, hb >= 0 ? resp[hb + 4 .. $].idup : "");
    } catch (Exception) {
        return Reply("io-error", "");
    }
}

ushort pickFreePort() {
    auto sock = new Socket(AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
    scope(exit) sock.close();
    sock.bind(new InternetAddress(InternetAddress.ADDR_ANY, cast(ushort) 0));
    return (cast(InternetAddress) sock.localAddress).port;
}

// ---------------------------------------------------------------------------
// One instance, one request, one SIGTERM.
// ---------------------------------------------------------------------------

struct Run {
    bool   ready;          // /api/registry answered 200 with a populated table
    string readyDiag;      // the last NOT-ready probe; cleared once ready, so
                           // a diagnostic never reads `ready=true(503 …)`
    string requestCode;    // the STATUS CODE of the one request, on its own
    string requestBody;    // and its body, so a floor can assert either
    bool   exited;         // the process was gone before the deadline
    long   exitMs = -1;    // how long SIGTERM took, when it worked
    string policy;         // GET /api/ui/policy on a survivor — the witness
    string logTail;
}

// `budgetMs` is generous on purpose: a green pays only the real exit latency
// (tens of ms), and only a FAILING cell waits the whole budget out.
enum int kExitBudgetMs = 8_000;

Run driveOne(string tag, string method, string path, string reqBody) {
    Run r;
    const port    = pickFreePort();
    const scratch = buildPath("/tmp", "vibe3d_sigterm_exit_"
                                    ~ thisProcessID().to!string ~ "_"
                                    ~ port.to!string ~ "_" ~ tag);
    mkdirRecurse(scratch);
    const logPath = buildPath(scratch, "vibe3d.log");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = scratch;

    auto logFile = File(logPath, "wb");
    auto pid = spawnProcess(["./vibe3d", "--test", "--http-port", port.to!string],
                            stdin, logFile, logFile, env);

    // Readiness is the ONE named gate: /api/registry answering 200 with a
    // populated command table. /api/model answers before registerCommands has
    // run, and a request posted into that window is refused with 503 — the
    // instance then dies on SIGTERM having done NOTHING, which is a green for
    // the wrong reason and is exactly how the first draft of this rig read.
    {
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < 60_000) {
            auto probe = once(port, "GET", "/api/registry", "");
            if (probe.code == "200" && probe.body_.canFind(`"mesh.select"`)) {
                r.ready     = true;
                r.readyDiag = "";   // the failing probes are history now
                break;
            }
            r.readyDiag = probe.code ~ " " ~ (probe.body_.length > 120
                                              ? probe.body_[0 .. 120] : probe.body_);
            Thread.sleep(20.msecs);
        }
    }

    if (r.ready) {
        auto reply = once(port, method, path, reqBody);
        r.requestCode = reply.code;
        r.requestBody = reply.body_;
        // Let the frame that runs the command reach the end of its flush, so
        // the document revision the guard reads is the one this request made.
        Thread.sleep(300.msecs);
    }

    // The kill, and its verdict. `tryWait`, never `kill(pid, 0)`: an unreaped
    // zombie answers `kill(pid, 0)` successfully and would score as survived.
    try { kill(pid.processID, SIGTERM); } catch (Exception) {}
    {
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < kExitBudgetMs) {
            auto st = tryWait(pid);
            if (st.terminated) {
                r.exited = true;
                r.exitMs = sw.peek.total!"msecs";
                break;
            }
            Thread.sleep(25.msecs);
        }
    }
    if (!r.exited) {
        // The survivor is still answering, so ask it why: the guard record
        // names the verdict that held the quit.
        r.policy = once(port, "GET", "/api/ui/policy", "").body_;
        try { kill(pid.processID, SIGKILL); } catch (Exception) {}
        try { wait(pid); } catch (Exception) {}
    }

    try {
        auto txt = readText(logPath);
        r.logTail = txt.length > 2000 ? txt[$ - 2000 .. $] : txt;
    } catch (Exception e) { r.logTail = "(log unreadable: " ~ e.msg ~ ")"; }
    if (exists(scratch)) try { rmdirRecurse(scratch); } catch (Exception) {}
    return r;
}

__gshared Run g_control;   // no edit — every candidate rule agrees it exits
__gshared Run g_edited;    // one mesh.select — the cell that separates them

struct QuitFrameRun {
    bool ready;
    Reply arm;
    Reply play;
    Reply save;
    bool savedNonEmpty;
    bool exited;
    string logTail;
}

QuitFrameRun driveQuitFrame() {
    QuitFrameRun r;
    const port = pickFreePort();
    const scratch = buildPath("/tmp", "vibe3d_quit_frame_"
                                    ~ thisProcessID().to!string ~ "_"
                                    ~ port.to!string);
    mkdirRecurse(scratch);
    const logPath = buildPath(scratch, "vibe3d.log");
    const savePath = buildPath(scratch, "after-quit.v3d");

    string[string] env;
    env["VIBE3D_CONFIG_DIR"] = scratch;
    env["VIBE3D_STALL_PRE_TOOL_TICK_MS"] = "5000";

    auto logFile = File(logPath, "wb");
    auto pid = spawnProcess(["./vibe3d", "--test", "--http-port", port.to!string],
                            stdin, logFile, logFile, env);

    {
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < 60_000) {
            auto probe = once(port, "GET", "/api/registry", "");
            if (probe.code == "200" && probe.body_.canFind(`"file.save"`)) {
                r.ready = true;
                break;
            }
            Thread.sleep(20.msecs);
        }
    }

    if (r.ready) {
        // tool.set arms the existing bounded pre-tool seam stall. Its reply is
        // sent before that stall begins, giving the HTTP thread five seconds to
        // load a due quit and queue file.save for the NEXT frame. Production
        // order then has to run HTTP replay first, continue through tickAll,
        // and execute file.save despite the accepted quit setting running=false.
        r.arm = once(port, "POST", "/api/script", "tool.set move");
        r.play = once(port, "POST", "/api/play-events",
            `{"t":0,"type":"SDL_QUIT"}` ~ "\n");
        r.save = once(port, "POST", "/api/command",
            `{"id":"file.save","params":{"path":"` ~ savePath ~ `"}}`);
    }

    if (exists(savePath)) {
        auto saved = readText(savePath);
        r.savedNonEmpty = saved.length > 100
                       && saved.canFind(`"vertices"`)
                       && saved.canFind(`"faces"`);
    }

    {
        auto sw = StopWatch(AutoStart.yes);
        while (sw.peek.total!"msecs" < kExitBudgetMs) {
            auto st = tryWait(pid);
            if (st.terminated) {
                r.exited = true;
                break;
            }
            Thread.sleep(25.msecs);
        }
    }
    if (!r.exited) {
        try { kill(pid.processID, SIGKILL); } catch (Exception) {}
        try { wait(pid); } catch (Exception) {}
    }

    try {
        auto txt = readText(logPath);
        r.logTail = txt.length > 2000 ? txt[$ - 2000 .. $] : txt;
    } catch (Exception e) { r.logTail = "(log unreadable: " ~ e.msg ~ ")"; }
    if (exists(scratch)) try { rmdirRecurse(scratch); } catch (Exception) {}
    return r;
}

__gshared QuitFrameRun g_quitFrame;

// `shared static this`, NOT `static this`: the per-thread form re-runs in every
// thread the process makes and would boot an editor per thread.
shared static this() {
    g_control = driveOne("control", "GET",  "/api/model",   "");
    g_edited  = driveOne("edited",  "POST", "/api/command",
        `{"id":"mesh.select","params":{"mode":"edges","indices":[0]}}`);
    g_quitFrame = driveQuitFrame();
}

string render(ref Run r) {
    return format("ready=%s(%s) reply=%s %s exited=%s afterMs=%d policy=%s"
                ~ "\n--- log tail ---\n%s",
                  r.ready, r.readyDiag.length ? r.readyDiag : "no diagnostic",
                  r.requestCode.length ? r.requestCode : "(no request)",
                  r.requestBody, r.exited, r.exitMs,
                  r.policy.length ? r.policy : "(none — it exited)", r.logTail);
}

string render(ref QuitFrameRun r) {
    return format("ready=%s arm=%s %s play=%s %s save=%s %s "
                ~ "savedNonEmpty=%s exited=%s\n--- log tail ---\n%s",
                  r.ready, r.arm.code, r.arm.body_, r.play.code, r.play.body_,
                  r.save.code, r.save.body_, r.savedNonEmpty, r.exited,
                  r.logTail);
}

// ---------------------------------------------------------------------------
// Floor. Both cells below are statements about an instance that came up and
// did the thing; over an instance that never wired itself they would hold
// vacuously, and "exited on SIGTERM" is exactly what a crashed boot looks like.
// ---------------------------------------------------------------------------
unittest {
    assert(g_control.ready,
        "4380 floor: the control instance never became ready — the cells below "
        ~ "would be measuring a boot failure.\n" ~ render(g_control));
    assert(g_edited.ready,
        "4380 floor: the edited instance never became ready.\n" ~ render(g_edited));
    // The CODE field, not a substring of the reply: `/api/model` answers with
    // a mesh, and "200" occurs in a vertex coordinate about as often as it
    // occurs in a status line.
    assert(g_control.requestCode == "200",
        "4380 floor: the control's GET /api/model did not answer 200; code was "
        ~ g_control.requestCode ~ ", body " ~ g_control.requestBody);
    assert(g_edited.requestCode == "200"
        && g_edited.requestBody.canFind(`"status":"ok"`),
        "4380 floor: mesh.select was not applied, so this instance recorded no "
        ~ "edit and the cell below would pass for the wrong reason: code "
        ~ g_edited.requestCode ~ ", body " ~ g_edited.requestBody);
}

// An accepted quit ends the loop only after its current frame. The non-empty
// saved document is the effect: it is produced by a real main-thread command
// queued behind the due HTTP replay quit, not by a trace written by this test.
unittest {
    assert(g_quitFrame.ready,
        "5170 quit-frame floor: the owned instance never exposed a populated "
        ~ "command registry.\n" ~ render(g_quitFrame));
    assert(g_quitFrame.arm.code == "200"
        && g_quitFrame.arm.body_.canFind(`"status":"ok"`),
        "5170 quit-frame floor: tool.set did not arm the pre-tool stall.\n"
        ~ render(g_quitFrame));
    assert(g_quitFrame.play.code == "200"
        && g_quitFrame.play.body_.canFind(`"status": "success"`),
        "5170 quit-frame floor: HTTP replay did not accept the due quit.\n"
        ~ render(g_quitFrame));
    assert(g_quitFrame.savedNonEmpty,
        "5170 accepted-quit frame witness: file.save queued after the due quit "
        ~ "did not execute on the same frame with a non-empty document.\n"
        ~ render(g_quitFrame));
    assert(g_quitFrame.save.code == "200"
        && g_quitFrame.save.body_.canFind(`"status":"ok"`),
        "5170 accepted-quit frame witness: the post-quit operation wrote an "
        ~ "artifact but did not complete its HTTP bridge reply.\n"
        ~ render(g_quitFrame));
    assert(g_quitFrame.exited,
        "5170 accepted-quit frame witness: the frame completed its queued "
        ~ "operation but the accepted quit did not end the process.\n"
        ~ render(g_quitFrame));
}

// ---------------------------------------------------------------------------
// Native acquisition witness (task 5170). SDL's installed signal handler turns
// SIGTERM into SDL_QUIT on the real process queue; unlike HTTP replay this does
// not call EventPlayer or its immediate sink. A ready control process that
// remains alive therefore means the main loop lost its native SDL poll.
// ---------------------------------------------------------------------------
unittest {
    assert(g_control.exited,
        "5170 native SDL queue witness: SIGTERM's SDL_QUIT was not acquired "
        ~ "by the main-loop poll within the exit budget.\n" ~ render(g_control));
}

// ---------------------------------------------------------------------------
// Cell 1 (the control, and it must STAY green): a clean instance exits.
// ---------------------------------------------------------------------------
unittest {
    assert(g_control.exited,
        "4380 cell 1: a --test instance that recorded NO edit did not exit "
        ~ format("within %d ms of SIGTERM. This is not the guard defect — "
                 ~ "something more basic broke the shutdown path.\n",
                 kExitBudgetMs) ~ render(g_control));
}

// ---------------------------------------------------------------------------
// Cell 2 (the defect): one recorded mesh edit must not make the process
// immortal. Reverting the window-close arm of `FileQuit.discardsUnsavedWork`
// reddens exactly this line, and the survivor's own `/api/ui/policy` in the
// message names the verdict that held it.
// ---------------------------------------------------------------------------
unittest {
    assert(g_edited.exited,
        "4380 cell 2: a --test instance that recorded ONE mesh edit did not "
        ~ format("exit within %d ms of SIGTERM. SIGTERM arrives as SDL_QUIT, "
                 ~ "becomes a `file.quit`, and the unsaved-work guard holds it "
                 ~ "behind a prompt that --test suppresses and nobody can "
                 ~ "answer.\n", kExitBudgetMs) ~ render(g_edited));
}
