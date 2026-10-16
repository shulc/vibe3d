module tests.unit.selection_projection_test;

import vibe3d.viewport.subpatch.subpatch_factories : subdivideCube;
import tests.unit.http_test_client : receiveUntilClosed;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.memory : GC;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import vibe3d.documents.model.document : Document, Layer, beginPreparedLayerRead;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.runtime.http.http_server : HttpServer, InProcessHttpTransport;
import vibe3d.mesh.core.mesh : makeCube;
import vibe3d.editing.selection.model.selection_projection : SelectionProjectionInput,
    SelectionProjectionReadModel, encodeSelectionProjection;
import vibe3d.editing.contracts.seltype : SelMode, SelType, SelTypeOrder;
import std.algorithm : canFind;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.stdio : writefln;
import std.string : indexOf;

private final class AsyncHttpReply {
    shared bool done;
    string wire;
    string failure;
}

private size_t threadIdentity() nothrow {
    try return cast(size_t) cast(void*) Thread.getThis();
    catch (Throwable) return 0;
}

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private Thread startHttpGet(ushort port, AsyncHttpReply reply) {
    auto client = new Thread({
        try {
            Socket socket;
            foreach (_; 0 .. 200) {
                try {
                    socket = new TcpSocket();
                    socket.connect(new InternetAddress("127.0.0.1", port));
                    break;
                } catch (Exception) {
                    if (socket !is null) socket.close();
                    socket = null;
                    Thread.sleep(5.msecs);
                }
            }
            if (socket is null)
                throw new Exception("server did not accept a connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             7.seconds);
            socket.send("GET /api/selection HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nConnection: close\r\n\r\n");
            receiveUntilClosed(socket, reply.wire);
        } catch (Exception e) {
            reply.failure = e.msg;
        }
        atomicStore(reply.done, true);
    });
    client.start();
    return client;
}

private void tickUntilDone(HttpServer server, AsyncHttpReply reply) {
    foreach (_; 0 .. 5000) {
        if (atomicLoad(reply.done)) return;
        server.tickAll();
        Thread.sleep(1.msecs);
    }
    assert(false, "0950 item F: genuine HTTP request did not complete "
        ~ "while tickAll was running");
}

private string responseBody(string wire) {
    auto split = wire.indexOf("\r\n\r\n");
    assert(split >= 0,
        "0950 item F: HTTP response had no header/body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private int[] ids(JSONValue value) {
    int[] result;
    foreach (entry; value.array) result ~= cast(int)entry.integer;
    return result;
}

unittest { // genuine HTTP selection service runs on tick thread and sees prepared shadow
    auto doc = Document.bootstrap(makeCube());
    auto layer = doc.primary;
    layer.meshRef().syncSelection();
    layer.meshRef().selectVertex(1);
    assert(layer.beginEnlistedMesh(),
        "0950 item F fixture: primary layer did not enlist a prepared shadow");
    scope(exit) layer.abortEnlistedMesh();
    layer.enlistedShadow().clearVertexSelection();
    layer.enlistedShadow().selectVertex(6);
    SelTypeOrder order;
    auto liveInput = SelectionProjectionInput(
        &doc, &order, EditMode.Vertices, &layer.meshRef());
    assert(ids(parseJSON(encodeSelectionProjection(liveInput))
            ["selectedVertices"]) == [1],
        "0950 item F fixture: the live layer mesh must carry distinct vertex 1");

    auto projection = new SelectionProjectionReadModel(() {
        return SelectionProjectionInput(
            &doc, &order, EditMode.Vertices, doc.activeMesh());
    });

    shared size_t callbackThread;
    shared int callbackCount;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionDataProvider(() {
        atomicStore(callbackThread, threadIdentity());
        atomicOp!"+="(callbackCount, 1);
        return projection.read();
    });
    server.markProvidersWired();
    immutable tickThread = threadIdentity();
    assert(tickThread != 0,
        "0950 item F fixture: known tick-thread identity must be populated");
    server.tickAll();
    server.start();
    scope(exit) server.stop();

    auto prepared = beginPreparedLayerRead(layer);
    scope(exit) prepared.close();
    auto okReply = new AsyncHttpReply();
    auto okClient = startHttpGet(port, okReply);
    tickUntilDone(server, okReply);
    okClient.join();
    assert(okReply.failure.length == 0,
        "0950 item F: genuine HTTP client failed: " ~ okReply.failure);
    assert(atomicLoad(callbackCount) == 1,
        "0950 item F thread identity: expected exactly one real provider callback");
    assert(atomicLoad(callbackThread) == tickThread,
        "0950 item F thread identity: /api/selection provider callback did "
        ~ "not run on the known tick thread");
    assert(okReply.wire.canFind("HTTP/1.1 200 OK"),
        "0950 item F: bridged selection request did not return 200: " ~ okReply.wire);
    auto payload = parseJSON(responseBody(okReply.wire));
    assert(ids(payload["selectedVertices"]) == [6],
        "0950 item F synthetic prepared-read witness: the deliberately open "
        ~ "scope must expose enlisted-shadow vertex 6, not live-layer vertex 1");

    server.setSelectionBridgeMaxItersForTest(2);
    auto inProcessReply = (new InProcessHttpTransport(server)).request(
        "GET", "/api/selection", "");
    assert(inProcessReply.statusCode == 200,
        "6750 transport parity: in-process /api/selection did not return 200: "
        ~ inProcessReply.body);
    assert(inProcessReply.body == responseBody(okReply.wire),
        "6750 transport parity: /api/selection bodies differ between socket "
        ~ "and in-process transports\nsocket: " ~ responseBody(okReply.wire)
        ~ "\nin-process: " ~ inProcessReply.body);
    writefln("[6750 transport parity] socket-body=%s", responseBody(okReply.wire));
    writefln("[6750 transport parity] in-process-body=%s", inProcessReply.body);
    server.setSelectionBridgeMaxItersForTest(2500);

    server.setSelectionDataProvider(() {
        throw new Exception("selection provider injected failure");
        return "";
    });
    auto errorReply = new AsyncHttpReply();
    auto errorClient = startHttpGet(port, errorReply);
    tickUntilDone(server, errorReply);
    errorClient.join();
    assert(errorReply.failure.length == 0,
        "0950 item F: provider-exception HTTP client failed: " ~ errorReply.failure);
    assert(errorReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(errorReply.wire).canFind("selection provider injected failure"),
        "0950 item F: provider exception must complete as the existing JSON 500 path: "
        ~ errorReply.wire);

    shared int timedOutProviderCalls;
    server.setSelectionDataProvider(() {
        atomicOp!"+="(timedOutProviderCalls, 1);
        return `{}`;
    });
    auto timeoutReply = new AsyncHttpReply();
    immutable timeoutStarted = MonoTime.currTime;
    auto timeoutClient = startHttpGet(port, timeoutReply);
    timeoutClient.join(); // deliberately no tick: exercise the bridge timeout contract
    immutable timeoutElapsed = MonoTime.currTime - timeoutStarted;
    assert(timeoutReply.failure.length == 0,
        "0950 item F: timeout HTTP client failed: " ~ timeoutReply.failure);
    assert(timeoutReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(timeoutReply.wire).canFind("timeout waiting for main thread"),
        "0950 item F: an unserviced selection request must complete through "
        ~ "the existing timeout path: "
        ~ timeoutReply.wire);
    assert(atomicLoad(timedOutProviderCalls) == 0,
        "0950 item F timeout: provider ran even though no tick serviced the request");
    assert(timeoutElapsed >= 4.seconds,
        "6750 selection timeout budget: the late unserviced request did not retain the restored 2500-iteration spin");
}
