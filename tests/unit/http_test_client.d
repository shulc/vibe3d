// The one read loop every unit-test HTTP client uses (task 7900). A blocking
// recv on a socket with SO_RCVTIMEO is NEVER restarted after a signal, even
// under SA_RESTART (signal(7)), and the GC's stop-the-world signals every
// thread. A client loop that reads `n <= 0` as "peer closed" therefore turns
// any collection that lands mid-read into an empty reply -- the server-side
// twin of this defect was fixed in task 0652 (http_transport.d
// interruptedBySignal). Here it surfaced once the module gate ran in worker
// processes: different heap, different collection moments, empty wires in
// request_result_ownership_test and a 120 s stall in
// history_replay_boundary_test. Card: doc/tasks/work/parallel-module-gate.md.
module tests.unit.http_test_client;

import core.time : Duration, MonoTime, seconds;
import std.socket : Socket;

/// Append everything `socket` delivers until the peer closes, a real error
/// occurs, or `budget` elapses. An interrupted receive is retried.
void receiveUntilClosed(Socket socket, ref string wire,
                        Duration budget = 60.seconds)
{
    immutable deadline = MonoTime.currTime + budget;
    ubyte[8192] buf;
    for (;;)
    {
        immutable n = socket.receive(buf[]);
        if (n > 0)
        {
            wire ~= cast(string) buf[0 .. n].idup;
            continue;
        }
        if (n < 0 && interrupted() && MonoTime.currTime < deadline)
            continue;
        break;
    }
}

private bool interrupted() nothrow @nogc
{
    version (Posix)
    {
        import core.stdc.errno : errno, EINTR;
        return errno == EINTR;
    }
    else
        return false;
}

version (linux) private extern (C) int gettid() nothrow @nogc; // glibc >= 2.30

version (linux)
unittest // a collection that lands mid-read must not end the read
{
    import core.atomic : atomicLoad, atomicStore;
    import core.memory : GC;
    import core.thread : Thread;
    import core.time : msecs;
    import std.conv : to;
    import std.file : readText;
    import std.format : format;
    import std.socket : socketPair, SocketOption, SocketOptionLevel;
    import std.string : strip;

    // The cell drives the SAME helper the HTTP tests call, over a socket pair
    // with the receive timeout those clients set.
    auto pair = socketPair();
    scope(exit) { pair[0].close(); pair[1].close(); }
    pair[0].setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);

    shared int tid;
    string wire;
    auto reader = new Thread({
        atomicStore(tid, gettid());
        receiveUntilClosed(pair[0], wire);
    });
    reader.start();

    // Wait until the reader is really parked in recv (state S), then collect:
    // the GC signals it, and the recv fails with EINTR.
    bool parked;
    foreach (_; 0 .. 2000)
    {
        const t = atomicLoad(tid);
        if (t)
        {
            try
            {
                const stat = readText(format("/proc/self/task/%d/stat", t));
                // Field 3, after the parenthesised command name.
                import std.string : lastIndexOf;
                const rest = stat[stat.lastIndexOf(')') + 2 .. $];
                if (rest.length && rest[0] == 'S')
                {
                    parked = true;
                    break;
                }
            }
            catch (Exception) {}
        }
        Thread.sleep(1.msecs);
    }
    assert(parked, "the reader thread never blocked in recv");
    foreach (_; 0 .. 3)
        GC.collect();

    pair[1].send("after-the-collection");
    pair[1].close();
    reader.join();
    assert(wire == "after-the-collection", format(
        "a GC collection during recv ended the read early: got `%s`", wire));
}

unittest // census: no unit-test client reads a socket except through the helper
{
    import std.algorithm : canFind, filter;
    import std.file : dirEntries, readText, SpanMode;
    import std.format : format;
    import std.path : baseName, buildPath, dirName, extension;

    enum root = dirName(__FILE_FULL_PATH__);
    string[] rawReaders;
    size_t users;
    foreach (e; dirEntries(root, SpanMode.depth)
                .filter!(e => e.isFile && e.name.extension == ".d"))
    {
        if (e.name == __FILE_FULL_PATH__)
            continue;
        const text = readText(e.name);
        if (text.canFind(".receive("))
            rawReaders ~= e.name;
        if (text.canFind("import tests.unit.http_test_client : receiveUntilClosed;"))
            ++users;
    }
    assert(rawReaders.length == 0, format(
        "these unit tests read a socket with their own loop; use "
      ~ "receiveUntilClosed so a GC signal does not end the read: %s", rawReaders));
    // Population floor, measured 2026-09-25 (eleven HTTP client files).
    assert(users == 11, format("%d unit-test files use receiveUntilClosed, expected 11", users));
}
