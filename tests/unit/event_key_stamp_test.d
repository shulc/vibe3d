module tests.unit.event_key_stamp_test;

import bindbc.sdl;
import eventlog : EventLogger, parseEventLog, setEventPlayerClockForTest,
    clearEventPlayerControlsForTest;
import std.file : readText, remove, tempDir;
import std.conv : to;
import std.path : buildPath;
import std.process : thisProcessID;
import std.algorithm.searching : canFind;
import std.string : splitLines;

unittest { // U4: both key stamps and KEYUP-only focus metadata survive parsing
    auto path = buildPath(tempDir(), "vibe3d_key_stamp_" ~
                          thisProcessID.to!string ~ ".jsonl");
    scope(exit) remove(path);
    setEventPlayerClockForTest(1000, 1000);
    scope(exit) clearEventPlayerControlsForTest();
    EventLogger logger;
    logger.open(path);
    SDL_Event e;
    e.type = SDL_KEYDOWN;
    e.key.keysym.sym = cast(SDL_Keycode)97;
    e.key.keysym.scancode = cast(SDL_Scancode)4;
    e.key.timestamp = 1234;
    logger.log(e, false);
    e.type = SDL_KEYUP;
    e.key.timestamp = 1235;
    logger.log(e, false);
    logger.close();
    auto text = readText(path);
    assert(text.canFind(`"ts":1234`), "U4 key timestamp was not recorded");
    assert(text.canFind(`"ts":1235`), "U4 key-up timestamp was not recorded");
    assert(text.canFind(`"focus":0`), "U4 key focus bit was not recorded");
    assert(!text.splitLines()[0].canFind(`"focus":`),
        "U4 key-down wrote unused focus metadata");
    auto parsed = parseEventLog(text);
    assert(parsed.accepted && parsed.log.entries.length == 2);
    assert(parsed.log.entries[0].event.common.timestamp == 1234,
        "U4 key timestamp did not survive parsing");
    assert(parsed.log.entries[0].windowFocused,
        "U4 key-down without focus metadata lost the legacy default");
    assert(parsed.log.entries[1].event.common.timestamp == 1235,
        "U4 key-up timestamp did not survive parsing");
    assert(!parsed.log.entries[1].windowFocused,
        "U4 key focus bit did not survive parsing");

    auto legacy = parseEventLog(
        `{"t":0,"type":"SDL_KEYUP","sym":32,"scan":44,"mod":0,"repeat":0,"ts":1234}`);
    assert(legacy.accepted && legacy.log.entries[0].windowFocused,
        "U4 a legacy key entry without focus must remain focused");
}
