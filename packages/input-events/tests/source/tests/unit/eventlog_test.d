// Module unittests for `eventlog`, moved verbatim out of source/eventlog.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.eventlog_test;

import bindbc.sdl;
import std.json;
import std.stdio : File;
import eventlog;

unittest { // EventLogger.close() is a no-op when already inactive
    EventLogger logger;
    logger.active = false;
    logger.close();
    assert(!logger.active);
}

unittest { // EventPlayer.tick() returns false immediately when inactive
    EventPlayer player;
    player.active = false;
    assert(player.tick() == false);
}

unittest { // EventPlayer.open: non-existent file returns false
    EventPlayer p;
    assert(!p.open("/nonexistent_path_for_unittest/file.txt"));
}
