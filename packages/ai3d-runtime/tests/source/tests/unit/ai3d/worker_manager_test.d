// Module unittests for `ai3d.worker_manager`, moved verbatim out of source/ai3d/worker_manager.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.ai3d.worker_manager_test;

import std.array   : replace;
import std.conv    : to;
import std.file    : exists, read, write, mkdirRecurse, getSize, dirEntries, SpanMode, thisExePath;
import std.json    : JSONValue, JSONType, parseJSON, JSONException;
import std.path    : buildPath, dirName, isAbsolute;
import std.process : environment, Pid, spawnProcess, tryWait, kill, wait;
import std.stdio   : File, stdin;
import core.time   : MonoTime, msecs, seconds;
import core.thread : Thread;
import log : logWarn;
import ai3d.stage_artifact : normalizeLocalWorkerUrl;
import std.file : tempDir, rmdirRecurse;
import std.random : uniform;
import ai3d.worker_manager;

// Hermetic sync-check: kAi3dDefaultPort / kAi3dDefaultModel against the
// python worker's own argparse defaults in
// tools/ai3d_worker/vibe3d_ai3d_worker/server.py. This repo layout (the
// worker checkout living alongside the editor checkout) is a dev-checkout
// convenience, not a build dependency — worker_manager.d never reads
// server.py at runtime (see the two enums' doc comments above) — so a
// machine that doesn't carry tools/ai3d_worker (another dev's box, a
// packaging/release CI image, `dub test` invoked from outside the repo
// root) must not fail here: skip silently when the file can't be found.
unittest {
    import std.file  : exists, readText;
    import std.regex : matchFirst, regex;

    enum serverPyPath = "tools/ai3d_worker/vibe3d_ai3d_worker/server.py";
    if (!exists(serverPyPath)) return;

    const src = readText(serverPyPath);

    auto portMatch = matchFirst(src,
        regex(`add_argument\("--port"[^)]*?default=(\d+)`));
    assert(!portMatch.empty,
        "server.py's --port argparse default has changed shape — update " ~
        "the regex above or the manual-sync comment on kAi3dDefaultPort");
    assert(portMatch[1].to!int == kAi3dDefaultPort,
        "kAi3dDefaultPort (" ~ kAi3dDefaultPort.to!string ~ ") no longer " ~
        "matches server.py's --port default (" ~ portMatch[1] ~ ") — the " ~
        "two are NOT wired together at runtime for the manually-started-" ~
        "worker case (see the constant's doc comment), only kept in sync " ~
        "by convention. Update kAi3dDefaultPort to match.");

    auto modelMatch = matchFirst(src,
        regex(`add_argument\("--trellis-model"[^)]*?default="([^"]+)"`));
    assert(!modelMatch.empty,
        "server.py's --trellis-model argparse default has changed shape " ~
        "— update the regex above or the manual-sync comment on " ~
        "kAi3dDefaultModel");
    assert(modelMatch[1] == kAi3dDefaultModel,
        "kAi3dDefaultModel (" ~ kAi3dDefaultModel ~ ") no longer matches " ~
        "server.py's --trellis-model default (" ~ modelMatch[1] ~ "). " ~
        "Update kAi3dDefaultModel to match.");
}
