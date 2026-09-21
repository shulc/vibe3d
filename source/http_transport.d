module http_transport;

version (web)
{
    // Task 6920: the browser keeps the router's compile-time shape but owns no
    // socket, worker thread, or wait primitive; the web-closure census pins it.
    void httpTransportSleep(Duration)(Duration) {}

    size_t httpTransportThreadIdentity() nothrow
    {
        // The browser target has one execution thread, so one non-zero identity
        // marks both the tick and in-process request sides as that same thread.
        return 1;
    }

    mixin template HttpServerTransport()
    {
        private shared bool isRunning;
        private ushort port;

        public void start() {}
        public void stop() {}
    }
}
else
{

/// Sleep used by the HTTP bridge's native wait loops. Keeping the thread
/// primitive here leaves request routing dependent only on a duration value.
void httpTransportSleep(Duration)(Duration delay)
{
    import core.thread : Thread;
    Thread.sleep(delay);
}

/// Opaque identity of the current native thread. Router state stores only the
/// integer and never depends on a `Thread` object.
size_t httpTransportThreadIdentity() nothrow
{
    import core.thread : Thread;
    try {
        return cast(size_t) cast(void*) Thread.getThis();
    } catch (Throwable) {
        return 0;
    }
}

/// Native socket/thread half of `HttpServer`. The template is mixed into the
/// router class, so the compiler pins the composition and the transport can
/// reach the router's private dispatcher without widening that boundary.
mixin template HttpServerTransport()
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : Duration, MonoTime, seconds;
    import std.conv : to;
    import std.socket;
    import std.string : split, strip, toLower;

    import log : logError, logInfo, logWarn;

    private Socket serverSocket;
    // WHY THIS IS `shared` AND WHY EVERY ACCESS GOES THROUGH core.atomic
    // (task 1710; the race was reported by the tsan lane on 2026-08-21).
    //
    // The flag is WRITTEN by the accept-loop thread (`start()`'s lambda, once
    // bind/listen have succeeded) and by the main thread (`stop()`), and it is
    // READ by both. Nothing synchronised any of that: it was a plain
    // non-shared bool, which in D means a racing access is undefined, not
    // merely unordered.
    //
    // What the HARDWARE is permitted to do: the load and the store are one
    // aligned byte, so nothing can tear — but on a weakly-ordered target
    // (aarch64; we ship macOS arm64) the accept thread's `isRunning = true`
    // carries NO happens-before edge for the `serverSocket = new TcpSocket()`
    // and `listen()` that precede it. A main thread that saw `true` was
    // entitled to see a stale `serverSocket`, and `stop()` — main thread —
    // dereferences exactly that field to close it.
    //
    // What the COMPILER is permitted to do: treat a non-shared field as
    // untouched by other threads, i.e. keep it in a register across a region
    // it can prove does no aliasing write, and fold `running()` (a trivial
    // `const` accessor, visible for inlining because dub compiles the package
    // as one unit) into the caller.
    //
    // Whether any caller DEPENDS on the answer — yes, both of them, which is
    // what makes this a defect and not a benign flag:
    //   * app.d's frame loop gates the whole HTTP drain on `running()`. A
    //     stale `false` there means requests are accepted and never answered,
    //     the exact failure the 0652 comment below calls the worst shape a
    //     harness can meet.
    //   * app.d's `scope(exit)` calls `stop()` only if `running()` is true,
    //     and `stop()` itself early-outs on the same flag. A stale `false` on
    //     either read means the accept loop is never asked to stop and never
    //     has its socket closed, so process teardown joins a thread parked in
    //     accept() — a hang, not a wrong pixel.
    // Sequentially-consistent order is the default and is kept: the store
    // happens twice in a process lifetime, so there is nothing to buy by
    // weakening it and a real cost to reasoning about it.
    private shared bool isRunning;

    private ushort port;
    private Thread serverThread;

    /**
     * Start the HTTP server in a separate thread
     */
    public void start() {
        if (atomicLoad(isRunning)) {
            logWarn("http", "Server is already running");
            return;
        }

        foreach (bridge; bridges) bridge.notifyStarted();
        serverThread = new Thread({
            import std.format : format;
            try {
                serverSocket = new TcpSocket();
                serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
                serverSocket.bind(new InternetAddress(port));
                serverSocket.listen(10);

                logInfo("http", format("HTTP server started on port %d", port));
                atomicStore(isRunning, true);

                while (atomicLoad(isRunning)) {
                    try {
                        Socket clientSocket = serverSocket.accept();
                        handleClient(clientSocket);
                    } catch (Exception e) {
                        if (atomicLoad(isRunning)) {
                            logWarn("http", "Error accepting client: " ~ e.msg);
                        }
                    }
                }
            } catch (Exception e) {
                logError("http", "Error starting server: " ~ e.msg);
            }
        });

        serverThread.start();
    }

    /**
     * Stop the HTTP server
     */
    public void stop() {
        if (!atomicLoad(isRunning)) {
            logWarn("http", "Server is not running");
            return;
        }

        foreach (bridge; bridges) bridge.notifyStopping();
        atomicStore(isRunning, false);
        if (serverSocket !is null) {
            // Connect to ourselves to unblock the accept() call in serverThread
            try {
                Socket unblockSocket = new TcpSocket();
                unblockSocket.connect(new InternetAddress("127.0.0.1", port));
                unblockSocket.close();
            } catch (Exception e) {
                // Ignore connection errors during shutdown
            }

            serverSocket.close();
            serverSocket = null;
        }

        if (serverThread !is null && serverThread.isRunning) {
            serverThread.join();
        }

        atomicStore(tickThreadIdentity_, 0);

        logInfo("http", "HTTP server stopped");
    }

    // --- Per-connection I/O budget ----------------------------------------
    // The accept loop is SINGLE-THREADED and calls handleClient INLINE, so a
    // peer that connects and then never sends a complete request header used
    // to park the one server thread in recv() forever. Meanwhile listen()'s
    // backlog keeps completing TCP handshakes, so every LATER client still
    // connects successfully and then waits forever — the server "accepts and
    // never answers". That is the worst failure shape a harness can meet: a
    // readiness probe that only checks connectivity PASSES while nothing will
    // ever be served, and the timeout surfaces much later, blamed on whatever
    // was being measured (task 0652).
    //
    // Three bounds close it. clientIoTimeout caps one blocking recv/send,
    // clientReadDeadline caps the whole request read, and clientWriteDeadline
    // caps a response whose peer keeps making only partial progress.
    // All three are enormous next to a real client, which sends its request
    // in one segment immediately. Hitting either is LOUD on stderr — closing a
    // connection without an answer must never be silent.
    //
    // Fields rather than manifest constants ONLY so an in-module unittest can
    // exercise the give-up paths in milliseconds instead of waiting the
    // production budget. Nothing in the app writes them.
    Duration clientIoTimeout     =  5.seconds;
    Duration clientReadDeadline  = 15.seconds;
    Duration clientWriteDeadline = 15.seconds;

    /// True when the last socket call failed only because a signal arrived.
    /// The GC's stop-the-world signals every thread, so a blocking recv() on
    /// the HTTP thread is interrupted routinely and for no fault of the peer.
    /// Treating that as end-of-request drops a perfectly good in-flight
    /// request and closes the connection with no reply — the exact failure
    /// this file exists to make impossible — so callers must retry instead.
    /// Check this BEFORE wouldHaveBlocked(): both read `errno`.
    private static bool interruptedBySignal() nothrow @nogc {
        version (Posix) {
            import core.stdc.errno : errno, EINTR;
            return errno == EINTR;
        } else {
            return false;
        }
    }

    // A blocking send may return a positive short count when the GC's signal
    // interrupts it after the kernel copied some bytes. Keep advancing the
    // SAME response until it is complete; task 6310's multi-megabyte fake
    // socket and handleClient census are the behavioural and wiring evidence.
    private static size_t sendHttpResponse(SocketLike)(
            SocketLike client, const(void)[] response, Duration deadline,
            out string failure) {
        immutable startedAt = MonoTime.currTime;
        size_t totalSent = 0;
        while (totalSent < response.length) {
            auto sent = client.send(response[totalSent .. $]);
            if (sent > 0) {
                totalSent += cast(size_t) sent;
                if (totalSent < response.length
                        && MonoTime.currTime - startedAt > deadline) {
                    failure = "send still incomplete after "
                        ~ deadline.to!string;
                    break;
                }
                continue;
            }
            if (sent < 0 && interruptedBySignal()) {
                if (MonoTime.currTime - startedAt <= deadline) continue;
                failure = "send still incomplete after " ~ deadline.to!string;
            } else {
                failure = sent < 0 ? lastSocketError() : "stopped reading";
            }
            break;
        }
        return totalSent;
    }

    version(unittest) {
        public static size_t sendHttpResponseForTest(SocketLike)(
                SocketLike client, const(void)[] response, Duration deadline,
                out string failure) {
            return sendHttpResponse(client, response, deadline, failure);
        }
    }

    /// Report a connection we accepted and are closing WITHOUT a response.
    /// A separate `nothrow` helper because its caller is handleClient's
    /// `finally` block, where D forbids a `catch` statement outright.
    private static void reportAbandoned(string peer, MonoTime startedAt, string why) nothrow {
        try {
            import std.format : format;
            logWarn("http", format(
                // json-num-exempt: formats elapsed time for a log, not a JSON body
                "closed connection from %s after %.1fs WITHOUT a response: peer %s",
                peer, (MonoTime.currTime - startedAt).total!"msecs" / 1000.0, why));
        } catch (Exception) {}
    }

    /**
     * Handle a client connection
     */
    private void handleClient(Socket client) {
        import std.format : format;

        immutable startedAt = MonoTime.currTime;
        string peer = "<unknown peer>";
        // Non-empty means "closing this connection WITHOUT a response", which
        // is precisely the event that must never pass unreported.
        string abandoned;

        try {
            try { peer = client.remoteAddress().toString(); } catch (Exception) {}
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, clientIoTimeout);
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, clientIoTimeout);

            // Read until we have the full header block (ends with \r\n\r\n)
            ubyte[] raw;
            ubyte[4096] chunk;
            ptrdiff_t n;
            size_t headerEnd;
            while (true) {
                n = client.receive(chunk[]);
                if (n == 0) break;  // peer closed cleanly
                if (n < 0) {
                    if (interruptedBySignal()) {
                        if (MonoTime.currTime - startedAt <= clientReadDeadline) continue;
                        abandoned = format("request header still incomplete after %s",
                                           clientReadDeadline);
                        break;
                    }
                    abandoned = wouldHaveBlocked()
                        ? format("sent no request data for %s", clientIoTimeout)
                        : format("receive failed: %s", lastSocketError());
                    break;
                }
                raw ~= chunk[0 .. n];
                // Search entire buffer for end-of-headers marker
                size_t searchFrom = raw.length > n + 3 ? raw.length - n - 3 : 0;
                for (size_t i = searchFrom; i + 3 < raw.length; ++i) {
                    if (raw[i] == '\r' && raw[i+1] == '\n' && raw[i+2] == '\r' && raw[i+3] == '\n') {
                        headerEnd = i + 4;
                        break;
                    }
                }
                if (headerEnd > 0) break;
                if (MonoTime.currTime - startedAt > clientReadDeadline) {
                    abandoned = format("request header still incomplete after %s",
                                       clientReadDeadline);
                    break;
                }
            }

            if (abandoned.length) return;  // reported by the `finally` below
            // A peer that connects and closes without sending is an ordinary
            // liveness probe, not a fault — stay quiet about it.
            if (raw.length == 0) return;

            string headerPart = cast(string)raw[0 .. headerEnd].idup;
            logInfo("http", "Received request: " ~ headerPart.split("\n")[0]);

            // Parse Content-Length from headers
            size_t contentLength = 0;
            foreach (line; headerPart.split("\n")) {
                string s = line.strip();
                if (s.length > 16 && s[0..16].toLower() == "content-length: ") {
                    try { contentLength = to!size_t(s[16..$].strip()); } catch (Exception) {}
                    break;
                }
            }
            // Read remaining body bytes
            ubyte[] bodyRaw = raw[headerEnd .. $];
            while (bodyRaw.length < contentLength) {
                n = client.receive(chunk[]);
                if (n == 0) break;  // peer closed cleanly; parse what arrived
                if (n < 0) {
                    if (interruptedBySignal()) {
                        if (MonoTime.currTime - startedAt <= clientReadDeadline) continue;
                        abandoned = format("body still incomplete (%d of %d bytes) after %s",
                                           bodyRaw.length, contentLength, clientReadDeadline);
                        break;
                    }
                    abandoned = wouldHaveBlocked()
                        ? format("stopped sending its body at %d of %d bytes (idle %s)",
                                 bodyRaw.length, contentLength, clientIoTimeout)
                        : format("receive failed reading body: %s", lastSocketError());
                    break;
                }
                bodyRaw ~= chunk[0 .. n];
                if (MonoTime.currTime - startedAt > clientReadDeadline) {
                    abandoned = format("body still incomplete (%d of %d bytes) after %s",
                                       bodyRaw.length, contentLength, clientReadDeadline);
                    break;
                }
            }
            if (abandoned.length) return;  // reported by the `finally` below

            HttpRequest httpRequest = parseRequest(headerPart, cast(string)bodyRaw.idup);
            HttpResponse response = handleRequest(httpRequest);

            string responseStr = formatResponse(response);
            string sendFailure;
            auto sent = sendHttpResponse(
                client, responseStr, clientWriteDeadline, sendFailure);
            if (sent != responseStr.length) {
                // A peer that stops reading stalls the send the same way a
                // silent peer stalled the receive — bounded by SNDTIMEO now,
                // but a half-delivered answer is still no answer, so say it.
                logWarn("http", format(
                    "peer %s took only %d of %d response bytes: %s",
                    peer, sent, responseStr.length, sendFailure));
            }
        } catch (Exception e) {
            logWarn("http", "Error handling client: " ~ e.msg);
        } finally {
            // The whole point of task 0652: a connection we accepted and did
            // not answer is invisible to every caller (their probe connected
            // fine, their request just never came back), so it has to be
            // audible here or nowhere.
            if (abandoned.length) reportAbandoned(peer, startedAt, abandoned);
            client.close();
        }
    }
}
}
