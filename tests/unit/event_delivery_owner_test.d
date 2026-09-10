// Task 5170: replay delivery is explicit per player, while the composition
// root preserves the measured frame ordering and the HTTP-off async carve-out.
// This is source-level by design for the HTTP-off cell: with no listener the
// HTTP suite has no observation channel, and adding one would widen this slice.
module tests.unit.event_delivery_owner_test;

import std.algorithm : count;
import std.exception : enforce;
import std.file      : readText;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private string bodyAt(string code, string marker)
{
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after source marker `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i)
    {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    enforce(false, "unterminated body after source marker `" ~ marker ~ "`");
    return null;
}

private ptrdiff_t requiredAt(string text, string marker)
{
    const at = text.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    return at;
}

unittest // ownership and both explicit producer handoffs
{
    const eventlog = blankNonCode(readText(
        buildPath(repoRoot, "source", "eventlog.d")));
    const http = blankNonCode(readText(
        buildPath(repoRoot, "source", "http_server.d")));
    const app = blankNonCode(readText(
        buildPath(repoRoot, "source", "app.d")));

    assert(eventlog.indexOf("g_directDispatch") < 0
        && eventlog.indexOf("setDirectEventDispatch") < 0
        && eventlog.indexOf("clearDirectEventDispatch") < 0,
        "5170 ownership witness: process-global replay dispatch returned");

    const player = bodyAt(eventlog, "struct EventPlayer");
    assert(player.indexOf("ImmediateEventSink immediateSink_") >= 0
        && player.indexOf("void setImmediateSink(") >= 0,
        "5170 ownership witness: EventPlayer no longer owns its immediate sink");
    assert(player.indexOf("_pushEvent(&e)") >= 0,
        "5170 ownership witness: callers without a sink lost SDL queue fallback");

    const setter = bodyAt(http, "void setEventPlayerSink(");
    assert(setter.indexOf("eventPlayer.setImmediateSink(sink)") >= 0,
        "5170 HTTP sink door no longer delegates to the server-owned player");

    const mainBody = bodyAt(app, "void main(string[] args)");
    assert(mainBody.count("evPlay.setImmediateSink(replaySink)") == 1
        && mainBody.count("httpServer.setEventPlayerSink(replaySink)") == 1,
        "5170 composition root must grant one sink to each replay producer");
}

unittest // frame order and the deliberately source-level HTTP-off cell
{
    const app = blankNonCode(readText(
        buildPath(repoRoot, "source", "app.d")));
    const mainBody = bodyAt(app, "void main(string[] args)");

    const cliReplay = requiredAt(mainBody, "evPlay.tick()");
    const httpReplay = requiredAt(mainBody, "httpServer.tickEventPlayer()");
    const tickAll = requiredAt(mainBody, "httpServer.tickAll()");
    const stall = requiredAt(mainBody, "preToolTickStall.waitAtSeam()");
    const aiDrain = requiredAt(mainBody, "ai3dController.drain(&onAi3dEvent)");
    const pollWorker = requiredAt(mainBody, "ai3dWorkerManager.pollWorker()");
    const pollInstall = requiredAt(mainBody, "ai3dWorkerManager.pollInstall()");
    const remesh = requiredAt(mainBody, "            tickRemeshJob();");
    const nativePoll = requiredAt(mainBody, "while (SDL_PollEvent(&event))");
    const momentum = requiredAt(mainBody, "if (ifs.anySpinning)");

    const runningGuard = bodyAt(mainBody, "if (httpServer.running)");
    assert(runningGuard.indexOf("httpServer.tickEventPlayer()") >= 0
        && runningGuard.indexOf("httpServer.tickAll()") >= 0,
        "5170 HTTP-running guard no longer owns replay and bridge service");
    assert(runningGuard.indexOf("ai3dController.drain") < 0
        && runningGuard.indexOf("pollWorker") < 0
        && runningGuard.indexOf("pollInstall") < 0
        && runningGuard.indexOf("tickRemeshJob") < 0,
        "5170 HTTP-off gate: async AI/remesh work moved inside httpServer.running");

    assert(cliReplay < httpReplay && httpReplay < tickAll && tickAll < stall
        && stall < aiDrain && aiDrain < pollWorker && pollWorker < pollInstall
        && pollInstall < remesh && remesh < nativePoll && nativePoll < momentum,
        "5170 frame order changed: CLI replay -> HTTP replay -> tickAll -> "
        ~ "stall -> AI drain -> worker/install -> remesh -> native poll -> momentum");
    assert(mainBody.count("httpServer.tickAll()") == 1,
        "5170 tickAll contract changed from exactly once per frame");

    assert(runningGuard.indexOf(
        "if (!scriptedInputHeld) httpServer.tickEventPlayer()") >= 0,
        "5170 scripted-input hold no longer blocks only HTTP replay");
    assert(runningGuard.indexOf(
        "if (!scriptedInputHeld) httpServer.tickAll()") < 0,
        "5170 scripted-input hold incorrectly blocks HTTP reset/status recovery");

    const pollBody = bodyAt(mainBody, "while (SDL_PollEvent(&event))");
    assert(pollBody.indexOf("router.processEvent(&event)") >= 0,
        "5170 native poll no longer converges on InputRouter.processEvent");
}

unittest // SDL_QUIT is accepted through the router's true tail
{
    const router = blankNonCode(readText(
        buildPath(repoRoot, "source", "input_router.d")));
    const process = bodyAt(router, "bool processEvent(SDL_Event* ev)");
    const quitAt = requiredAt(process, "case SDL_QUIT:");
    const nextAt = requiredAt(process, "case SDL_WINDOWEVENT:");
    enforce(quitAt < nextAt, "SDL_QUIT arm no longer precedes SDL_WINDOWEVENT");
    const quitArm = process[cast(size_t)quitAt .. cast(size_t)nextAt];
    assert(quitArm.indexOf("return false") < 0
        && quitArm.indexOf("break;") >= 0
        && process[cast(size_t)nextAt .. $].indexOf("return true;") >= 0,
        "5170 accepted SDL_QUIT stopped dispatch instead of returning through "
        ~ "InputRouter.processEvent's true tail");
}
