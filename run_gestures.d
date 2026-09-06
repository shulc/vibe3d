#!/usr/bin/env rdmd
/**
 * vibe3d GESTURE lane — replays gesture logs through the SHIPPED UI path.
 *
 *   ./run_gestures.d                 # every cell
 *   ./run_gestures.d bevel           # cells whose name contains "bevel"
 *   ./run_gestures.d --display 98    # pin the Xvfb display (default: xvfb-run -a)
 *   ./run_gestures.d --port 8770     # pin the HTTP port
 *   ./run_gestures.d -v              # per-cell process output on failure
 *
 * WHERE THIS LIVES, and why it is not a third argument to `run_test.d`
 * ------------------------------------------------------------------
 * This is a SEPARATE, hand-invoked lane beside the two routine ones
 * (`./run_test.d --no-build` and `dub test --config=tests`). It is not wired
 * into `run_test.d`: that runner owns an LPT scheduler and a run-lock flock
 * around ONE long-lived `vibe3d --test` per worker, and every cell here needs
 * the opposite — a fresh process per cell, no `--test`, and a display of its
 * own. Sharing the lock would serialise two unrelated resources; sharing the
 * worker would defeat the whole point, since the worker is the `--test`
 * process this lane exists to avoid.
 *
 * WHAT IT MEASURES (task 4483)
 * ----------------------------
 * The routine lane drives `vibe3d --test`, and `--test` gates the entire UI
 * chrome. CITED BY SYMBOL, NEVER BY LINE — this header's first cut named
 * `app.d:6622` for the window creation and `app.d:4251` for the arm door, and
 * by the time anyone read them back those lines were `showFaceHover` and a
 * shortcut-id validator. What `--test` actually gates:
 *
 *   - the saved viewport layout is never restored — `applyLayout(
 *     g_prefs.viewportLayout)` in app.d sits under an `if (!testMode)`;
 *   - no "ViewportHost" window is created — `DockBuilderDockWindow(
 *     "ViewportHost", vpRegion)` is in the dockspace seed's `!testMode` arm,
 *     while the `--test` arm seeds "Layers" + "Viewport##0" and nothing else;
 *   - and it is not two branches. Re-measure rather than trusting this count:
 *
 *       grep -cE 'if \(!?(command\.g_)?testMode' source/app.d
 *       25                                            # measured 2026-09-06
 *
 * So the routine lane measures an application that is structurally not the one
 * we ship. This lane replays the same kind of gesture log WITHOUT `--test` and
 * treats the process's own fate as part of the result.
 *
 * THE CONFIGURATION IT NEEDS (task 4483, constraint O2)
 * ----------------------------------------------------
 * app.d's `startHttpServer` default is picked by version:
 *
 *     version (ReleaseBuild) bool startHttpServer = false;
 *     else                   bool startHttpServer = true;
 *
 * `ReleaseBuild` is declared by NO dub configuration — not `modeling`, not
 * `modeling-noai`, not `with-render`, not `tests`; it arrives only as an
 * explicit `--d-version=ReleaseBuild` when a release is packaged. So on a
 * plain `dub build` the HTTP server is up WITHOUT `--test`, and that is what
 * lets this lane drive the shipped UI path and still read state back.
 *
 * This lane therefore runs on `modeling` (a plain `dub build`) or any other
 * configuration that does not pass `-version=ReleaseBuild`. On a release
 * binary every cell REFUSES with "http never answered" rather than going
 * quietly green — the readiness gate below is what makes that true, and it is
 * deliberate: a lane that cannot read the effect must not report success.
 *
 * THREE OUTCOMES, BECAUSE THE EXIT CODE IS NOT A VERDICT (constraint O1)
 * ---------------------------------------------------------------------
 * Measured 2026-09-05: a HEALTHY run does not exit by itself. A harmless log
 * without `--test` gives EXIT=124 (our own timeout) with
 * `[eventlog] EventPlayer: playback finished` present and no exception. So
 * `assert exit == 0` would fail every healthy cell and `assert exit != 1`
 * would pass a hang. The verdict is built from the process OUTPUT and the
 * observable effect, never from the exit code, which is only reported:
 *
 *     Crashed       — an uncaught exception is in the output
 *     Finished      — "playback finished" is in the output
 *     DidNotFinish  — neither; the log never drained
 *
 * EVERY CELL ASSERTS AN EFFECT (constraint O3, and it is not hypothetical)
 * -----------------------------------------------------------------------
 * A log the application did not CONSUME looks exactly like a healthy run:
 * played, alive, nothing thrown. Measured on this very lane's first cell —
 * without `--test` a replayed CLICK selects nothing at all, because
 * `InputRouter.processEvent`'s `!app.testMode && !ifs.viewportInputAllowed()`
 * gate drops mouse events when the viewport window is not hovered, and ImGui's
 * hover flag never sees the replayed pointer (task 4490).
 * A mouse cell would have been green over a gesture that did nothing.
 *
 * So each cell names an endpoint and a substring that is FALSE before the
 * gesture and TRUE after it. The baselines were measured, not assumed: a
 * cold instance answers `/api/tool/state` with `{}`, and its
 * `selTypeOrder` is `["vertex","edge","polygon","item"]`.
 *
 * TIME IN A GESTURE LOG IS MILLISECONDS (task 4483, constraint O5)
 * ---------------------------------------------------------------
 * `EventPlayer.load` stores the log's `t` straight into
 * `EventPlayer.Entry.timeMs`, and `EventPlayer.tick` compares that field
 * against elapsed milliseconds (`entries[idx].timeMs <= nowMs`). A log
 * written as if `t` were seconds fires entirely inside the first frame,
 * before the chrome exists — which is how the 8-line repro in task 4482
 * behaves. Cells here place their gesture at t >= 5000 ms so the application
 * is warm (HTTP answers at ~4 s on this host) and then wait for the
 * "playback finished" line rather than for a wall-clock guess.
 */

module run_gestures;

extern(C) __gshared string[] rt_options = ["gcopt=parallel:0"];

import std.algorithm : canFind, filter, any;
import std.array     : array, join;
import std.conv      : to;
import std.file      : exists, readText, mkdirRecurse, remove;
import std.format    : format;
import std.getopt    : getopt, config;
import std.path      : buildPath, dirName, absolutePath;
import std.process   : spawnProcess, execute, kill, wait, tryWait, Config,
                       ProcessPipes, environment;
import std.regex     : matchFirst, regex;
import std.stdio     : File, writeln, writefln, stdout;
import std.string    : strip, splitLines, indexOf;
import core.thread   : Thread;
import core.time     : dur, seconds, msecs;

// ---------------------------------------------------------------------------
// A cell. `expectSub` must be a string the endpoint does NOT answer before the
// gesture — see the header. `redToday` marks a cell we KNOW is failing on the
// current tree, so the lane's own output says which reds are the pinned defect
// and which would be news.
// ---------------------------------------------------------------------------
struct Cell {
    string name;
    string log;         // path under tests/gestures/
    bool   testMode;    // pass --test (the CONTROL cells only)
    string endpoint;    // read back over HTTP after "playback finished"
    string expectSub;   // must appear in the answer
    string proves;      // what the effect proves; printed on failure
    bool   redToday;    // known-failing on today's tree (task 4482)
}

// POPULATION FLOOR (constraint O4). The count is named here, asserted below,
// and printed in the summary. A census over an empty set passes honestly and
// says nothing.
enum size_t kCellCount = 6;

immutable Cell[] kCells = [
    // ---- green cells: keyboard gestures whose effect is real without --test
    Cell("mode-polygons", "mode_polygons.log", false,
         "/api/selection", `"selTypeOrder":["polygon","vertex","edge","item"]`,
         "the `3` key reached the mode funnel; a cold instance answers "
         ~ `["vertex","edge","polygon","item"]`, false),

    Cell("mode-order-poly-then-edge", "mode_order_poly_then_edge.log", false,
         "/api/selection", `"selTypeOrder":["edge","polygon","vertex","item"]`,
         "BOTH keys arrived AND in order — the front is most-recent-first, so "
         ~ "this string is reachable only by 3 then 2", false),

    Cell("arm-move-hotkey", "arm_move_hotkey.log", false,
         "/api/tool/state", `"tool":"xfrm"`,
         "the INTERACTIVE arm door works without --test: `W` armed a tool "
         ~ "through app.d's `activateToolById` -> `toolHost.activate` -> "
         ~ "`armPreparedTool(ToolTransition.interactiveArm, ...)`; a cold "
         ~ "instance answers `{}`", false),

    // ---- the control, and it must sit ABOVE the reds: same gesture, --test on
    Cell("arm-poly-bevel-under-test", "arm_poly_bevel_hotkey.log", true,
         "/api/tool/state", `"tool":"polyBevel"`,
         "the SAME log under --test arms cleanly — so the reds below are the "
         ~ "chrome, not a broken fixture", false),

    // ---- WAS the reds of 4482/4491; both arm now, so neither is `redToday`.
    // Task 4491 moved the bevel tools' preview-image capture above the
    // `before.filled` early return, which a COLD arm never reaches — the
    // fifth conjunct of `preparedParamUpdateMatches` was therefore false by
    // construction and the arm refused. The flag came off in that same lane:
    // while it stood, a re-broken arm counted as a KNOWN red and this lane
    // would have banked the regression as expected.
    Cell("arm-poly-bevel-hotkey", "arm_poly_bevel_hotkey.log", false,
         "/api/tool/state", `"tool":"polyBevel"`,
         "Shift+B must arm poly.bevel without killing the process (task 4482) "
         ~ "AND actually arm it (task 4491)",
         false),

    Cell("arm-edge-bevel-hotkey", "arm_edge_bevel_hotkey.log", false,
         "/api/tool/state", `"tool":"edgeBevel"`,
         "B must arm edge.bevel without killing the process — the same defect "
         ~ "as 4482 on a second tool, found by this lane; and the same "
         ~ "cold-arm refusal as poly.bevel (task 4491)", false),
];

enum Outcome { Crashed, Finished, DidNotFinish }

struct Result {
    Outcome outcome;
    int     exitCode;
    string  exceptionLine;   // the uncaught exception, verbatim, when Crashed
    string  answer;          // the endpoint's answer, when it could be read
    bool    effectSeen;
    bool    httpAnswered;
    string  outPath;
}

__gshared bool  gVerbose;
__gshared int   gDisplay = -1;
__gshared int   gPort    = 8770;
__gshared int   gBudget  = 45;   // seconds a single cell may take

string repoRoot() { return __FILE_FULL_PATH__.dirName; }
string scratchDir() { return buildPath(repoRoot(), ".gesture-lane"); }

/// curl one endpoint; empty string when nothing answered.
string httpGet(string path) {
    auto r = execute(["curl", "-s", "-m", "3",
                      format("http://127.0.0.1:%d%s", gPort, path)]);
    return r.status == 0 ? r.output : "";
}

/// The PID currently LISTENING on our port, or 0.
///
/// The readiness and teardown gates both key on the PORT, never on a process
/// name: this host runs many lanes at once and `pkill -f vibe3d` would take
/// out someone else's instance (and, historically, the caller's own shell).
/// Waiting for the process to vanish is also the wrong gate — what the next
/// cell needs is for the port to be BINDABLE again.
int portHolder() {
    auto r = execute(["ss", "-ltnp"]);
    if (r.status != 0) return 0;
    foreach (line; r.output.splitLines) {
        if (!line.canFind(format(":%d ", gPort))) continue;
        auto m = line.matchFirst(regex(`pid=([0-9]+)`));
        if (!m.empty) return m[1].to!int;
    }
    return 0;
}

bool portFree() { return portHolder() == 0; }

void freePort(int budgetSec) {
    foreach (i; 0 .. budgetSec) {
        const holder = portHolder();
        if (holder == 0) return;
        // SIGTERM first, SIGKILL once it has had a few seconds.
        execute(["kill", i < 3 ? "-TERM" : "-KILL", holder.to!string]);
        Thread.sleep(1.seconds);
    }
}

Result runCell(const Cell cell) {
    Result res;
    res.exitCode = int.min;

    mkdirRecurse(scratchDir());
    res.outPath = buildPath(scratchDir(), cell.name ~ ".out");
    if (res.outPath.exists) res.outPath.remove();

    const logPath = buildPath(repoRoot(), "tests", "gestures", cell.log);
    if (!logPath.exists) throw new Exception("missing gesture log: " ~ logPath);

    freePort(15);

    string[] argv = ["xvfb-run"];
    if (gDisplay >= 0) argv ~= ["-n", gDisplay.to!string];
    else               argv ~= ["-a"];
    argv ~= [buildPath(repoRoot(), "vibe3d"),
             "--playback", logPath,
             "--http-port", gPort.to!string];
    if (cell.testMode) argv ~= "--test";

    auto sink = File(res.outPath, "w");
    auto pid  = spawnProcess(argv, File("/dev/null"), sink, sink);

    // Wait for the log to drain OR the process to die, whichever comes first.
    // The budget is a cap, not the verdict: a healthy cell does not exit.
    bool exited;
    foreach (i; 0 .. gBudget) {
        Thread.sleep(1.seconds);
        auto w = tryWait(pid);
        if (w.terminated) { exited = true; res.exitCode = w.status; break; }
        const text = res.outPath.exists ? res.outPath.readText : "";
        if (text.canFind("playback finished")) break;
    }

    // Read the effect BEFORE teardown, and only while the process still lives:
    // this is the check running at the right MOMENT, not merely the right one.
    if (!exited) {
        res.answer = httpGet(cell.endpoint);
        res.httpAnswered = res.answer.strip.length > 0;
        res.effectSeen = res.httpAnswered && res.answer.canFind(cell.expectSub);
    }

    freePort(15);
    if (!exited) {
        try { kill(pid); } catch (Exception) {}
        try { res.exitCode = wait(pid); } catch (Exception) {}
    }

    const text = res.outPath.exists ? res.outPath.readText : "";
    foreach (line; text.splitLines)
        if (line.canFind("object.Exception") || line.canFind("core.exception")) {
            res.exceptionLine = line.strip;
            break;
        }

    if (res.exceptionLine.length)             res.outcome = Outcome.Crashed;
    else if (text.canFind("playback finished")) res.outcome = Outcome.Finished;
    else                                        res.outcome = Outcome.DidNotFinish;

    return res;
}

int main(string[] args) {
    getopt(args,
        config.passThrough,
        "v|verbose", &gVerbose,
        "display",   &gDisplay,
        "port",      &gPort,
        "budget",    &gBudget);

    const filters = args[1 .. $];

    // POPULATION FLOOR (O4): the count is asserted before anything runs, so a
    // lane that silently lost its cells cannot report a clean sweep.
    assert(kCells.length == kCellCount,
        format("gesture cell census: expected %d cells, found %d",
               kCellCount, kCells.length));
    assert(kCellCount > 0, "gesture lane has no cells — a census over an "
        ~ "empty set passes honestly and says nothing");

    if (!buildPath(repoRoot(), "vibe3d").exists) {
        writeln("run_gestures: ./vibe3d not built — run `dub build` first.");
        return 2;
    }

    writefln("gesture lane: %d cells declared (floor asserted), port %d, %s",
        kCells.length, gPort,
        gDisplay >= 0 ? format("display :%d", gDisplay) : "xvfb-run -a");
    writeln("configuration: any build WITHOUT -version=ReleaseBuild "
        ~ "(plain `dub build` = `modeling`); a release binary exposes no HTTP "
        ~ "and every cell refuses.");
    writeln();

    size_t ran, passed, failed, unexpected;
    string[] failLines;

    foreach (cell; kCells) {
        if (filters.length && !filters.any!(f => cell.name.canFind(f))) continue;
        ++ran;
        stdout.writef("  %-28s ... ", cell.name);
        stdout.flush();

        auto res = runCell(cell);
        const ok = res.outcome == Outcome.Finished && res.effectSeen;

        string verdict;
        final switch (res.outcome) {
            case Outcome.Crashed:
                verdict = "CRASHED  " ~ res.exceptionLine; break;
            case Outcome.DidNotFinish:
                verdict = "DID NOT FINISH (log never drained)"; break;
            case Outcome.Finished:
                verdict = res.effectSeen
                    ? "ok"
                    : (res.httpAnswered
                        ? "EFFECT NOT OBSERVED — wanted " ~ cell.expectSub
                          ~ " in " ~ cell.endpoint ~ ", got " ~ res.answer.strip
                        : "http never answered on " ~ cell.endpoint);
                break;
        }

        if (ok) {
            ++passed;
            writefln("ok   (exit %d, effect seen)", res.exitCode);
        } else {
            ++failed;
            if (!cell.redToday) ++unexpected;
            writefln("%s  [%s]", cell.redToday ? "RED (known, 4482)" : "RED",
                     verdict);
            failLines ~= format("  %-28s %s\n      proves: %s\n      output: %s",
                cell.name, verdict, cell.proves, res.outPath);
        }
    }

    writeln();
    if (failLines.length) {
        writeln("failures:");
        foreach (l; failLines) writeln(l);
        writeln();
    }
    writefln("Total: %d cells, %d ok, %d red (%d unexpected)",
        ran, passed, failed, unexpected);

    // RUNTIME POPULATION FLOOR (O4, second half). The census asserted above is
    // COMPILE-TIME: it proves the table still declares six cells, and says
    // nothing about how many of them a given invocation drove. A filter that
    // matches nothing leaves `ran` at 0, and every counter below it at 0 too,
    // so the verdict reads "no reds" — green over an empty set, which is the
    // exact defect this lane was written against. Refuse instead, with its own
    // exit code, so a mistyped filter in a script cannot be banked as a pass.
    if (ran == 0) {
        writefln("run_gestures: filter matched no cell%s — 0 cells ran, "
            ~ "which is a refusal, not a pass.",
            filters.length ? " (" ~ filters.join(", ") ~ ")" : "");
        return 2;
    }

    // The pinned reds are a RESULT, not an error: this lane exists to hold a
    // live crash red until it is fixed. Exit 1 while any red remains, so the
    // lane cannot be mistaken for green, and 2 when a red is one nobody
    // declared.
    if (unexpected) return 2;
    return failed ? 1 : 0;
}
