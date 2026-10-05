// Opt-in keep-alive on the test HTTP server (task 9461). A request that says
// `Connection: keep-alive` keeps its connection for the next request; any
// other request is answered and closed, which is what every read-until-closed
// client relies on; and a parked idle connection never blocks a new client.
module tests.unit.http_keep_alive_test;

import tests.unit.http_test_client : receiveUntilClosed;
import tests.unit.http_test_client : receiveOneResponse;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import http_server : HttpServer;
import std.algorithm : canFind;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
    TcpSocket;

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private Socket connectTo(ushort port) {
    foreach (_; 0 .. 200) {
        auto socket = new TcpSocket();
        try {
            socket.connect(new InternetAddress("127.0.0.1", port));
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             5.seconds);
            return socket;
        } catch (Exception) {
            socket.close();
            Thread.sleep(5.msecs);
        }
    }
    assert(false, "9461: the server never accepted a connection");
}

private string request(string connection) {
    return "GET /no-such-page HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        ~ (connection.length ? "Connection: " ~ connection ~ "\r\n" : "")
        ~ "\r\n";
}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.markProvidersWired();
    server.start();
    scope(exit) if (server.running) server.stop();

    // 1. The opt-in: answered with keep-alive and left open.
    auto kept = connectTo(port);
    scope(exit) kept.close();
    kept.send(request("keep-alive"));
    string first;
    receiveOneResponse(kept, first, 5.seconds);
    assert(first.canFind("404") && first.canFind("Connection: keep-alive"),
        "9461 opt-in: a keep-alive request was not answered as keep-alive: "
        ~ first);

    // 2. While that connection sits idle, a plain client is served and closed.
    // A server that waited on the idle connection would leave this read empty
    // until the receive timeout.
    immutable startedAt = MonoTime.currTime;
    auto plain = connectTo(port);
    scope(exit) plain.close();
    plain.send(request(""));
    string closedWire;
    receiveUntilClosed(plain, closedWire, 5.seconds);
    assert(closedWire.canFind("404") && closedWire.canFind("Connection: close"),
        "9461 default: a request without the opt-in must be answered and "
        ~ "closed while another connection is parked: " ~ closedWire);
    assert(MonoTime.currTime - startedAt < 3.seconds,
        "9461 no serialization: the parked connection delayed a new client");

    // 3. The parked connection serves a second request, then honours close.
    kept.send(request("keep-alive"));
    string second;
    receiveOneResponse(kept, second, 5.seconds);
    assert(second.canFind("Connection: keep-alive"),
        "9461 reuse: the kept connection did not serve a second request: "
        ~ second);
    kept.send(request("close"));
    string lastWire;
    receiveUntilClosed(kept, lastWire, 5.seconds);
    assert(lastWire.canFind("Connection: close"),
        "9461 close on a kept connection: " ~ lastWire);
}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.markProvidersWired();
    server.clientKeepAliveIdle = 200.msecs;
    server.start();
    scope(exit) if (server.running) server.stop();

    // 4. Two requests in one segment: the surplus is a pipelined request the
    // server does not parse, so it answers the first and closes at once.
    auto piped = connectTo(port);
    scope(exit) piped.close();
    immutable pipedAt = MonoTime.currTime;
    piped.send(request("keep-alive") ~ request("keep-alive"));
    string pipedWire;
    receiveUntilClosed(piped, pipedWire, 5.seconds);
    assert(pipedWire.canFind("Connection: close")
        && MonoTime.currTime - pipedAt < 3.seconds,
        "9461 surplus bytes: a pipelined connection must be closed: "
        ~ pipedWire);

    // 5. A parked connection idle past clientKeepAliveIdle is closed.
    auto idle = connectTo(port);
    scope(exit) idle.close();
    idle.send(request("keep-alive"));
    string idleFirst;
    receiveOneResponse(idle, idleFirst, 5.seconds);
    assert(idleFirst.canFind("Connection: keep-alive"), idleFirst);
    immutable idleAt = MonoTime.currTime;
    string idleRest;
    receiveUntilClosed(idle, idleRest, 5.seconds);
    assert(idleRest.length == 0 && MonoTime.currTime - idleAt < 3.seconds,
        "9461 idle expiry: a parked connection outlived clientKeepAliveIdle");

}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.markProvidersWired();
    server.clientKeepAliveIdle = 60.seconds;
    server.start();
    scope(exit) if (server.running) server.stop();

    // 6. At most kMaxIdleClients stay parked: one more evicts the oldest.
    Socket[] parked;
    scope(exit) foreach (c; parked) c.close();
    foreach (i; 0 .. HttpServer.kMaxIdleClients + 1) {
        parked ~= connectTo(port);
        parked[$ - 1].send(request("keep-alive"));
        string wire;
        receiveOneResponse(parked[$ - 1], wire, 5.seconds);
        assert(wire.canFind("Connection: keep-alive"), wire);
    }
    assert(parked.length == 33, "9461 eviction rig: population changed");
    immutable evictAt = MonoTime.currTime;
    string evicted;
    receiveUntilClosed(parked[0], evicted, 3.seconds);
    assert(evicted.length == 0 && MonoTime.currTime - evictAt < 2.seconds,
        "9461 eviction: the oldest parked connection was not closed");
    parked[1].send(request("keep-alive"));
    string survivor;
    receiveOneResponse(parked[1], survivor, 5.seconds);
    assert(survivor.canFind("Connection: keep-alive"),
        "9461 eviction: a younger parked connection was closed: " ~ survivor);

    // 7. stop() closes every parked connection.
    immutable stopAt = MonoTime.currTime;
    server.stop();
    string afterStop;
    receiveUntilClosed(parked[2], afterStop, 5.seconds);
    assert(afterStop.length == 0 && MonoTime.currTime - stopAt < 3.seconds,
        "9461 stop: a parked connection survived the server");
}
