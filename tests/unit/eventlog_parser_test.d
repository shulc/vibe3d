module tests.unit.eventlog_parser_test;

import bindbc.sdl : KMOD_ALT, SDL_Event, SDL_KEYDOWN, SDL_MOUSEMOTION;
import eventlog : EventPlayer, parseEventLog;
import std.algorithm : count;
import std.exception : enforce;
import std.file      : readText;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private EventPlayer seededPlayer()
{
    SDL_Event e;
    e.type = SDL_MOUSEMOTION;
    e.motion.x = 91;
    EventPlayer player;
    player.entries = [EventPlayer.Entry(17.0, e, KMOD_ALT)];
    player.idx = 1;
    player.active = true;
    player.mouseX = 91;
    player.mouseY = 37;
    player.recordedViewport.vpX = 3;
    player.recordedViewport.vpY = 5;
    player.recordedViewport.vpW = 701;
    player.recordedViewport.vpH = 509;
    player.recordedViewport.valid = true;
    return player;
}

private void assertPlayerUntouched(const ref EventPlayer player, string cell)
{
    assert(player.entries.length == 1 && player.entries[0].timeMs == 17.0
        && player.entries[0].event.motion.x == 91,
        cell ~ ": parser changed the seeded player's event storage");
    assert(player.idx == 1 && player.active && player.mouseX == 91
        && player.mouseY == 37,
        cell ~ ": parser changed the seeded player's playback state");
    assert(player.recordedViewport.valid
        && player.recordedViewport.vpX == 3
        && player.recordedViewport.vpY == 5
        && player.recordedViewport.vpW == 701
        && player.recordedViewport.vpH == 509,
        cell ~ ": parser changed the seeded player's VIEWPORT remap");
}

unittest // P1 garbage: WHEN parsing completes, reject one skipped line
{
    auto player = seededPlayer();
    const parsed = parseEventLog("not json");
    assert(parsed.log.skipped == 1,
        "P1 population floor: garbage must account for exactly one skipped line");
    assert(parsed.log.entries.length == 0 && parsed.error.length != 0,
        "P1 garbage must return an error and no owned events");
    assertPlayerUntouched(player, "P1 garbage");
}

unittest // P2 empty: WHEN parsing completes, reject zero playable events
{
    auto player = seededPlayer();
    const parsed = parseEventLog("");
    assert(parsed.log.skipped == 0,
        "P2 population floor: an empty body has exactly zero nonblank lines");
    assert(parsed.log.entries.length == 0 && parsed.error.length != 0,
        "P2 empty input must return an error and no owned events");
    assertPlayerUntouched(player, "P2 empty");
}

unittest // P3 no VIEWPORT: WHEN parsing completes, preserve inheritance intent
{
    auto player = seededPlayer();
    const parsed = parseEventLog(
        `{"t":7,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}`);
    assert(parsed.log.entries.length == 1 && parsed.log.skipped == 0,
        "P3 population floor: the no-VIEWPORT log must own exactly one event");
    assert(parsed.error.length == 0 && !parsed.log.viewport.valid,
        "P3 no-VIEWPORT log must be accepted without replacing inherited metadata");
    assert(parsed.log.entries[0].event.type == SDL_KEYDOWN
        && parsed.log.entries[0].timeMs == 7.0,
        "P3 no-VIEWPORT log parsed the wrong owned event");
    assertPlayerUntouched(player, "P3 no VIEWPORT");
}

unittest // P4 valid: WHEN parsing completes, return owned events plus metadata
{
    auto player = seededPlayer();
    char[] body = (
        `{"t":0,"type":"VIEWPORT","vpX":11,"vpY":13,"vpW":640,"vpH":480,"fovY":0.7}`
        ~ "\ninvalid\n"
        ~ `{"t":9,"type":"SDL_MOUSEMOTION","x":101,"y":203,"xrel":2,"yrel":3,"state":0,"mod":0}`).dup;
    auto parsed = parseEventLog(cast(string)body);
    body[] = ' ';

    assert(parsed.log.entries.length == 1 && parsed.log.skipped == 1,
        "P4 population floor: valid mixed input must own one event and skip one line");
    assert(parsed.error.length == 0 && parsed.log.viewport.valid
        && parsed.log.viewport.vpX == 11 && parsed.log.viewport.vpY == 13
        && parsed.log.viewport.vpW == 640 && parsed.log.viewport.vpH == 480,
        "P4 valid input lost its locally parsed VIEWPORT metadata");
    assert(parsed.log.entries[0].event.type == SDL_MOUSEMOTION
        && parsed.log.entries[0].event.motion.x == 101
        && parsed.log.entries[0].event.motion.y == 203,
        "P4 parser result borrowed the caller's body instead of owning the event");
    assertPlayerUntouched(player, "P4 valid");
}

private string bodyAt(string code, string marker)
{
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after source marker `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    enforce(false, "unterminated body after source marker `" ~ marker ~ "`");
    return null;
}

unittest // W1 production wiring: WHEN the route handles a test-mode POST
{
    const source = blankNonCode(readText(
        buildPath(repoRoot, "source", "http_server.d")));
    const route = bodyAt(source, "private void route_apiPlayEvents(");
    const body = bodyAt(source, "private void servePlayEvents(");
    const parseAt = body.indexOf("parseEventLog(request.body)");
    const rejectAt = body.indexOf("if (!parsed.accepted())");
    const submitAt = body.indexOf("playEventsBridge.submitOwned(");

    assert(route.count("servePlayEvents(request, response)") == 1,
        "W1 wrapper floor: play-events route must call its body exactly once");
    assert(body.count("parseEventLog(request.body)") == 1
        && body.count("playEventsBridge.submitOwned(") == 1,
        "W1 population floor: play-events body must have one parser call and one owned submit");
    assert((route ~ body).indexOf("eventPlayer.") < 0
        && (route ~ body).indexOf("playbackController.accept(") < 0,
        "W1 production wrapper/body bypassed owned playback acceptance");
    assert(parseAt >= 0 && rejectAt > parseAt && submitAt > rejectAt,
        "W1 play-events body must parse and reject before its owned submit");
}
