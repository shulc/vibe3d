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
