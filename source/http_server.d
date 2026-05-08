module http_server;

import std.socket;
import std.stdio;
import std.string;
import std.conv;
import std.algorithm;
import std.array;
import std.datetime;
import std.json;
import core.thread;
import core.atomic;

// For event player functionality
import bindbc.sdl;
import eventlog;
import argstring : parseArgstring, ParsedLine;

/**
 * Simple HTTP server implementation for D applications
 */
class HttpServer {
    private Socket serverSocket;
    private bool isRunning;
    private ushort port;
    private Thread serverThread;
    private alias ModelDataProvider = string delegate();
    private ModelDataProvider modelDataProvider;
    private alias DetailedModelDataProvider = string delegate();
    private DetailedModelDataProvider detailedModelDataProvider;
    private bool useDetailedProvider = false;
    private alias CameraDataProvider = string delegate();
    private CameraDataProvider cameraDataProvider;
    private alias SelectionDataProvider = string delegate();
    private SelectionDataProvider selectionDataProvider;
    private alias RecordedEventsProvider = string delegate();
    private RecordedEventsProvider recordedEventsProvider;
    private alias ToolPipeProvider = string delegate();
    private ToolPipeProvider toolpipeProvider;
    // /api/toolpipe/eval — runs pipeline.evaluate once and returns the
    // resulting ActionCenterPacket + AxisPacket as JSON. Used by the
    // modo_diff parity harness to read vibe3d's pipe state directly
    // for a given selection without needing to drive the actual tool.
    private alias ToolPipeEvalProvider = string delegate();
    private ToolPipeEvalProvider toolpipeEvalProvider;
    // /api/snap — POST. Body is the snap-query JSON ({cursor, sx, sy,
    // excludeVerts}); response is the SnapResult JSON. Used by the
    // 7.3 unit tests to probe snap math directly without driving an
    // interactive Move drag through play-events. Read-only, so served
    // straight from the HTTP thread (same convention as
    // toolpipeEvalProvider) — tests are quiescent during probing.
    private alias SnapQueryProvider = string delegate(string requestBody);
    private SnapQueryProvider snapQueryProvider;
    private alias ResetHandler = void delegate(string primitiveType, bool empty);
    private ResetHandler resetHandler;
    // POST /api/camera — sync bridge to set the live View. Used by
    // the modo_diff cross-engine drag test to align vibe3d's camera
    // with MODO's before replaying a drag through /api/play-events.
    private alias CameraSetHandler = void delegate(JSONValue params);
    private CameraSetHandler cameraSetHandler;
    private shared long camSetSubmittedEpoch;
    private shared long camSetCompletedEpoch;
    private JSONValue pendingCamSet;
    private string    pendingCamSetError;
    private shared long resetSubmittedEpoch;
    private shared long resetCompletedEpoch;
    private string resetPendingType;     // primitive type for the in-flight reset
    private bool   resetPendingEmpty;    // true → empty scene, ignore primitiveType
    private bool testMode = false;

    // ----- /api/command synchronous bridge ---------------------------------
    // The HTTP thread fills pendingCmdId/Params, bumps submittedEpoch, and
    // spins on completedEpoch. The main thread runs the command via
    // commandHandler from tickCommand() and bumps completedEpoch.
    private alias CommandHandler = void delegate(string id, string paramsJson);
    private CommandHandler commandHandler;
    private shared long submittedEpoch;
    private shared long completedEpoch;
    private string pendingCmdId;
    private string pendingCmdParams;
    private string pendingCmdError;

    // ----- /api/select synchronous bridge ----------------------------------
    private alias SelectionHandler = void delegate(string mode, int[] indices);
    private SelectionHandler selectionHandler;
    private shared long selSubmittedEpoch;
    private shared long selCompletedEpoch;
    private string pendingSelMode;
    private int[]  pendingSelIndices;
    private string pendingSelError;

    // ----- /api/transform synchronous bridge -------------------------------
    private alias TransformHandler = void delegate(string kind, JSONValue params);
    private TransformHandler transformHandler;
    private shared long xfSubmittedEpoch;
    private shared long xfCompletedEpoch;
    private string    pendingXfKind;
    private JSONValue pendingXfParams;
    private string    pendingXfError;

    // ----- /api/undo + /api/redo synchronous bridge ------------------------
    // The handler returns true on success (an entry was undone/redone) or
    // false on stack-empty / revert-failure. /api/history is a read-only
    // provider that can be served from the HTTP thread directly (no
    // main-thread sync) since the labels list is a snapshot at request
    // time and any race just yields slightly stale labels.
    private alias UndoRedoHandler = bool delegate();
    private UndoRedoHandler undoHandler;
    private UndoRedoHandler redoHandler;
    private shared long undoSubmittedEpoch;
    private shared long undoCompletedEpoch;
    private bool   pendingUndoIsRedo;
    private bool   pendingUndoResult;

    private alias HistoryProvider = string delegate();   // returns JSON
    private HistoryProvider historyProvider;

    // ----- /api/history/replay provider ------------------------------------
    // Returns the canonical argstring line for undoStack[index], or "" when
    // the index is out of range. Runs on the HTTP thread (read-only snapshot).
    private alias ReplayProvider = string delegate(size_t index);
    private ReplayProvider replayProvider;

    // ----- /api/refire synchronous bridge ----------------------------------
    // POST /api/refire {"action":"begin"|"end"} opens or closes a refire
    // block on the history. Tools call refireBegin/refireEnd directly on
    // the main thread; this endpoint exists for HTTP-driven tests.
    private alias RefireHandler = void delegate(string action);
    private RefireHandler refireHandler;
    private shared long refireSubmittedEpoch;
    private shared long refireCompletedEpoch;
    private string pendingRefireAction;
    private string pendingRefireError;

    // Event player for handling event playback via HTTP
    private EventPlayer eventPlayer;

    public this(ushort port = 8080) {
        this.port = port;
        this.isRunning = false;
        this.modelDataProvider = null;
        this.eventPlayer = EventPlayer();
    }

    /**
     * Set the model data provider callback
     */
    public void setModelDataProvider(ModelDataProvider provider) {
        this.modelDataProvider = provider;
        this.useDetailedProvider = false;
    }

    /**
     * Set the detailed model data provider callback
     */
    public void setDetailedModelDataProvider(DetailedModelDataProvider provider) {
        this.detailedModelDataProvider = provider;
        this.useDetailedProvider = true;
    }

    /**
     * Set the camera data provider callback
     */
    public void setCameraDataProvider(CameraDataProvider provider) {
        this.cameraDataProvider = provider;
    }

    public void setSelectionDataProvider(SelectionDataProvider provider) {
        this.selectionDataProvider = provider;
    }

    public void setRecordedEventsProvider(RecordedEventsProvider provider) {
        this.recordedEventsProvider = provider;
    }

    /// Phase 7.0 — Tool Pipe inspection endpoint. The provider returns a
    /// JSON snapshot of the active pipeline (registered stages + their
    /// task codes / ordinals / enabled flags).
    public void setToolPipeProvider(ToolPipeProvider provider) {
        this.toolpipeProvider = provider;
    }

    /// JSON snapshot of pipeline evaluation results — center, axis basis,
    /// and per-cluster pivots/axes when ACEN/AXIS are in cluster mode.
    public void setToolPipeEvalProvider(ToolPipeEvalProvider provider) {
        this.toolpipeEvalProvider = provider;
    }

    /// Phase 7.3 — `/api/snap` query endpoint. Provider takes the raw
    /// request body (JSON) and returns the SnapResult JSON.
    public void setSnapQueryProvider(SnapQueryProvider provider) {
        this.snapQueryProvider = provider;
    }

    private alias BevvertProvider = string delegate(int vert);
    private BevvertProvider bevvertProvider;

    public void setBevvertProvider(BevvertProvider provider) {
        this.bevvertProvider = provider;
    }

    public void setTestMode(bool enabled) { testMode = enabled; }

    public int  playerMouseX()    const { return eventPlayer.mouseX; }
    public int  playerMouseY()    const { return eventPlayer.mouseY; }
    public bool playerMouseDown() const { return eventPlayer.mouseDown; }
    public bool playerFinished()  const { return !eventPlayer.active; }

    /**
     * Set the reset handler callback
     */
    public void setResetHandler(ResetHandler handler) {
        this.resetHandler = handler;
    }

    /// Set the POST /api/camera handler. Called on the main thread with
    /// the parsed JSON body — sets View azimuth/elevation/distance/focus
    /// to the requested values.
    public void setCameraSetHandler(CameraSetHandler handler) {
        this.cameraSetHandler = handler;
    }

    /**
     * Set the command handler callback. The handler runs on the main thread,
     * synchronously with respect to the HTTP request: see tickCommand().
     * The handler should throw on failure; the message is forwarded to the client.
     */
    public void setCommandHandler(CommandHandler handler) {
        this.commandHandler = handler;
    }

    /**
     * Set the selection handler callback. Same synchronous main-thread
     * dispatch as setCommandHandler — see tickSelection().
     */
    public void setSelectionHandler(SelectionHandler handler) {
        this.selectionHandler = handler;
    }

    /**
     * Set the transform handler callback. Same synchronous main-thread
     * dispatch as the others — see tickTransform().
     */
    public void setTransformHandler(TransformHandler handler) {
        this.transformHandler = handler;
    }

    /**
     * Set the undo/redo callbacks. Same main-thread sync as the others.
     * Returns true if a stack entry was applied, false on stack-empty or
     * revert failure.
     */
    public void setUndoHandler(UndoRedoHandler handler) { this.undoHandler = handler; }
    public void setRedoHandler(UndoRedoHandler handler) { this.redoHandler = handler; }

    /**
     * Set the /api/history JSON provider. Snapshot-at-request-time; runs
     * on the HTTP thread — provider must be safe to call concurrently with
     * apply/revert (or the caller must own a quick mutex).
     */
    public void setHistoryProvider(HistoryProvider provider) {
        this.historyProvider = provider;
    }

    /**
     * Set the replay provider — returns the canonical argstring line for
     * undoStack[index], or "" when the index is out of range. The provider
     * runs on the HTTP thread and must be safe to call concurrently with the
     * main thread (reading a snapshot is sufficient).
     */
    public void setReplayProvider(ReplayProvider provider) {
        this.replayProvider = provider;
    }

    /**
     * Set the refire handler — main-thread callback that opens/closes a
     * refire block on the command history. action is "begin" or "end".
     */
    public void setRefireHandler(RefireHandler handler) {
        this.refireHandler = handler;
    }

    /**
     * Start the HTTP server in a separate thread
     */
    public void start() {
        if (isRunning) {
            stderr.writeln("Server is already running");
            return;
        }

        serverThread = new Thread({
            try {
                serverSocket = new TcpSocket();
                serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
                serverSocket.bind(new InternetAddress(port));
                serverSocket.listen(10);

                stderr.writeln("HTTP server started on port ", port);
                isRunning = true;

                while (isRunning) {
                    try {
                        Socket clientSocket = serverSocket.accept();
                        handleClient(clientSocket);
                    } catch (Exception e) {
                        if (isRunning) {
                            stderr.writeln("Error accepting client: ", e.msg);
                        }
                    }
                }
            } catch (Exception e) {
                stderr.writeln("Error starting server: ", e.msg);
            }
        });

        serverThread.start();
    }

    /**
     * Stop the HTTP server
     */
    public void stop() {
        if (!isRunning) {
            stderr.writeln("Server is not running");
            return;
        }

        isRunning = false;
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

        stderr.writeln("HTTP server stopped");
    }

    /**
     * Handle a client connection
     */
    private void handleClient(Socket client) {
        try {
            // Read until we have the full header block (ends with \r\n\r\n)
            ubyte[] raw;
            ubyte[4096] chunk;
            ptrdiff_t n;
            size_t headerEnd;
            while (true) {
                n = client.receive(chunk[]);
                if (n <= 0) break;
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
            }

            if (raw.length == 0) return;

            string headerPart = cast(string)raw[0 .. headerEnd].idup;
            stderr.writeln("Received request: ", headerPart.split("\n")[0]);

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
                if (n <= 0) break;
                bodyRaw ~= chunk[0 .. n];
            }

            HttpRequest httpRequest = parseRequest(headerPart, cast(string)bodyRaw.idup);
            HttpResponse response = handleRequest(httpRequest);

            string responseStr = formatResponse(response);
            client.send(responseStr);
        } catch (Exception e) {
            stderr.writeln("Error handling client: ", e.msg);
        } finally {
            client.close();
        }
    }

    /**
     * Parse an HTTP request from separate header and body strings.
     */
    private HttpRequest parseRequest(string headers, string body) {
        auto lines = headers.split("\n");
        if (lines.length == 0)
            return new HttpRequest("GET", "/", "HTTP/1.1");

        auto parts = lines[0].strip().split(' ');
        string method      = parts.length >= 1 ? parts[0] : "GET";
        string path        = parts.length >= 2 ? parts[1] : "/";
        string httpVersion = parts.length >= 3 ? parts[2] : "HTTP/1.1";

        auto httpRequest = new HttpRequest(method, path, httpVersion);

        foreach (line; lines[1 .. $]) {
            string s = line.strip();
            auto colonPos = s.indexOf(":");
            if (colonPos > 0) {
                httpRequest.headers[s[0 .. colonPos].strip()] = s[colonPos + 1 .. $].strip();
            }
        }

        httpRequest.body = body;
        return httpRequest;
    }

    /**
     * Handle an HTTP request and generate a response
     */
    private HttpResponse handleRequest(HttpRequest request) {
        HttpResponse response = new HttpResponse();

        // Simple routing
        if (request.path == "/") {
            response.statusCode = 200;
            response.body = "<html><body><h1>Welcome to Vibe3D HTTP Server</h1>" ~
                           "<p>Server is running successfully!</p>" ~
                           "<p>Available endpoints:</p>" ~
                           "<ul><li>/status - Get application status</li>" ~
                           "<li>/info - Get application information</li>" ~
                           "<li>/api/model - Get current model state</li>" ~
                           "<li>/api/command - Execute one command (JSON {\"id\":...\"params\":...} OR argstring \"name arg:val ...\")</li>" ~
                           "<li>/api/script - Execute multi-line script (line-by-line argstring)</li>" ~
                           "<li>tool.set &lt;toolId&gt; [off] [name:val ...] - activate/deactivate a tool</li>" ~
                           "<li>tool.attr &lt;toolId&gt; &lt;name&gt; &lt;value&gt; - set parameter on active tool</li>" ~
                           "<li>tool.doApply - apply active tool one-shot (snapshot-based undo)</li>" ~
                           "<li>tool.reset [&lt;toolId&gt;] - reset active tool's parameters</li>" ~
                           "<li>/api/history/replay - POST {\"index\":N} — re-execute undoStack[N] against current state</li></ul>" ~
                           "</body></html>";
            response.headers["Content-Type"] = "text/html";
        } else if (request.path == "/status") {
            response.statusCode = 200;
            response.body = "{\"status\": \"running\", \"timestamp\": \"" ~
                           Clock.currTime.toISOExtString() ~ "\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/info") {
            response.statusCode = 200;
            response.body = "{\"name\": \"Vibe3D\", \"description\": \"Simple 3D modeller inspired by MODO and LightWave\", \"version\": \"1.0\"}";
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/model") {
            if (useDetailedProvider && detailedModelDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = detailedModelDataProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve detailed model data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else if (modelDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = modelDataProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve model data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Model data provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/selection") {
            if (selectionDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = selectionDataProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve selection data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Selection data provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/toolpipe/eval") {
            if (toolpipeEvalProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = toolpipeEvalProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"toolpipe eval provider failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"toolpipe eval provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/toolpipe") {
            if (toolpipeProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = toolpipeProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"toolpipe provider failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 200;
                response.body = "{\"stages\":[]}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/snap" && request.method == "POST") {
            if (snapQueryProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = snapQueryProvider(request.body);
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\":\"snap query failed\",\"message\":\"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\":\"snap query provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/camera" && request.method == "POST") {
            if (cameraSetHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"camera-set handler not set"}`;
            } else {
                try {
                    pendingCamSet = parseJSON(request.body);
                    pendingCamSetError = "";
                    long my = atomicOp!"+="(camSetSubmittedEpoch, 1);
                    enum int maxIters = 2500;
                    int iters = 0;
                    while (atomicLoad(camSetCompletedEpoch) < my) {
                        if (++iters > maxIters) {
                            pendingCamSetError = "timeout waiting for main thread";
                            break;
                        }
                        Thread.sleep(2.msecs);
                    }
                    if (pendingCamSetError.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ pendingCamSetError.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/camera") {
            if (cameraDataProvider !is null) {
                try {
                    response.statusCode = 200;
                    response.body = cameraDataProvider();
                    response.headers["Content-Type"] = "application/json";
                } catch (Exception e) {
                    response.statusCode = 500;
                    response.body = "{\"error\": \"Failed to retrieve camera data\", \"message\": \"" ~
                                   e.msg.replace("\"", "\\\"") ~ "\"}";
                    response.headers["Content-Type"] = "application/json";
                }
            } else {
                response.statusCode = 500;
                response.body = "{\"error\": \"Camera data provider not set\"}";
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/bevvert") && request.method == "GET") {
            response.headers["Content-Type"] = "application/json";
            if (bevvertProvider is null) {
                response.statusCode = 500;
                response.body = `{"error":"bevvert provider not set"}`;
            } else {
                int vert = parseQueryInt(request.path, "vert", -1);
                if (vert < 0) {
                    response.statusCode = 400;
                    response.body = `{"error":"missing or invalid 'vert' query param"}`;
                } else {
                    try {
                        response.statusCode = 200;
                        response.body = bevvertProvider(vert);
                    } catch (Exception e) {
                        response.statusCode = 400;
                        response.body = `{"error":"`
                                        ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                    }
                }
            }
        } else if (request.path == "/api/recorded-events" && request.method == "GET") {
            if (recordedEventsProvider !is null) {
                string data = recordedEventsProvider();
                if (data is null) {
                    response.statusCode = 404;
                    response.body = `{"error":"no recording available — press F1 to start, F2 to stop"}`;
                } else {
                    response.statusCode = 200;
                    response.body = data;
                    response.headers["Content-Type"] = "text/plain";
                }
            } else {
                response.statusCode = 500;
                response.body = `{"error":"recorded events provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path.startsWith("/api/reset") && request.method == "POST") {
            if (resetHandler !is null) {
                resetPendingType  = parseQueryString(request.path, "type", "");
                string emptyParam = parseQueryString(request.path, "empty", "");
                resetPendingEmpty = (emptyParam == "true" || emptyParam == "1");
                long my = atomicOp!"+="(resetSubmittedEpoch, 1);
                enum int maxIters = 2500;
                int iters = 0;
                while (atomicLoad(resetCompletedEpoch) < my) {
                    if (++iters > maxIters) break;  // give up; main thread stuck
                    Thread.sleep(2.msecs);
                }
                response.statusCode = 200;
                response.body = `{"status":"ok"}`;
            } else {
                response.statusCode = 500;
                response.body = `{"error":"Reset handler not set"}`;
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/play-events/status" && request.method == "GET") {
            import std.format : format;
            bool done = !eventPlayer.active;
            response.statusCode = 200;
            response.body = format(`{"finished":%s,"total":%d,"remaining":%d}`,
                done ? "true" : "false",
                eventPlayer.entries.length,
                done ? 0 : eventPlayer.entries.length - eventPlayer.idx);
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/transform" && request.method == "POST") {
            if (transformHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"transform handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("kind" !in j || j["kind"].type != JSONType.string)
                        throw new Exception("missing 'kind' string field");
                    pendingXfKind   = j["kind"].str;
                    pendingXfParams = j;  // pass full request body for handler
                    pendingXfError  = "";
                    long my = atomicOp!"+="(xfSubmittedEpoch, 1);
                    enum int maxIters = 2500;
                    int iters = 0;
                    while (atomicLoad(xfCompletedEpoch) < my) {
                        if (++iters > maxIters) {
                            pendingXfError = "timeout waiting for main thread";
                            break;
                        }
                        Thread.sleep(2.msecs);
                    }
                    if (pendingXfError.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ pendingXfError.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/select" && request.method == "POST") {
            if (selectionHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"selection handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("mode" !in j || j["mode"].type != JSONType.string)
                        throw new Exception("missing 'mode' string field");
                    if ("indices" !in j || j["indices"].type != JSONType.array)
                        throw new Exception("missing 'indices' array field");
                    pendingSelMode = j["mode"].str;
                    int[] idx;
                    foreach (n; j["indices"].array) {
                        if (n.type != JSONType.integer && n.type != JSONType.uinteger)
                            throw new Exception("indices must be integers");
                        idx ~= cast(int)n.integer;
                    }
                    pendingSelIndices = idx;
                    pendingSelError   = "";
                    long my = atomicOp!"+="(selSubmittedEpoch, 1);
                    enum int maxIters = 2500;
                    int iters = 0;
                    while (atomicLoad(selCompletedEpoch) < my) {
                        if (++iters > maxIters) {
                            pendingSelError = "timeout waiting for main thread";
                            break;
                        }
                        Thread.sleep(2.msecs);
                    }
                    if (pendingSelError.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ pendingSelError.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/command" && request.method == "POST") {
            if (commandHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"command handler not set"}`;
            } else {
                try {
                    string body_ = request.body;
                    // Detect JSON vs argstring by first non-whitespace character.
                    size_t bi = 0;
                    while (bi < body_.length &&
                           (body_[bi] == ' '  || body_[bi] == '\t' ||
                            body_[bi] == '\n'  || body_[bi] == '\r')) bi++;
                    if (bi >= body_.length)
                        throw new Exception("empty body");
                    bool isJson = (body_[bi] == '{');

                    if (isJson) {
                        auto j = parseJSON(body_);
                        if ("id" !in j || j["id"].type != JSONType.string)
                            throw new Exception("missing 'id' string field");
                        pendingCmdId     = j["id"].str;
                        pendingCmdParams = ("params" in j) ? j["params"].toString : "";
                    } else {
                        auto parsed = parseArgstring(body_);
                        if (parsed.isEmpty)
                            throw new Exception("empty argstring");
                        pendingCmdId     = parsed.commandId;
                        pendingCmdParams = parsed.params.toString();
                    }

                    pendingCmdError  = "";
                    long my = atomicOp!"+="(submittedEpoch, 1);
                    // Wait for main thread to drain — bounded at ~5s.
                    enum int maxIters = 2500;  // 2500 * 2ms = 5s
                    int iters = 0;
                    while (atomicLoad(completedEpoch) < my) {
                        if (++iters > maxIters) {
                            pendingCmdError = "timeout waiting for main thread";
                            break;
                        }
                        Thread.sleep(2.msecs);
                    }
                    if (pendingCmdError.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ pendingCmdError.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path.startsWith("/api/script") && request.method == "POST") {
            // Multi-line argstring script: execute each non-empty/non-comment
            // line through the same main-thread bridge as /api/command.
            // ?continue=true keeps running after errors; default stops on first.
            bool continueOnError =
                (parseQueryString(request.path, "continue", "") == "true");

            if (commandHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"command handler not set"}`;
            } else {
                import std.array  : Appender;
                import std.format : format;

                struct LineResult {
                    int    lineNo;
                    string command;
                    bool   ok;
                    string message; // non-empty on error
                }

                LineResult[] results;
                bool anyError = false;

                auto lines_ = request.body.split('\n');
                int lineNo  = 0;

                outer: foreach (rawLine; lines_) {
                    ++lineNo;
                    try {
                        auto parsed = parseArgstring(rawLine);
                        if (parsed.isEmpty) continue; // blank / comment

                        pendingCmdId     = parsed.commandId;
                        pendingCmdParams = parsed.params.toString();
                        pendingCmdError  = "";

                        long my = atomicOp!"+="(submittedEpoch, 1);
                        enum int maxIters = 2500; // 2500 * 2ms = 5s per line
                        int iters = 0;
                        while (atomicLoad(completedEpoch) < my) {
                            if (++iters > maxIters) {
                                pendingCmdError = "timeout waiting for main thread";
                                break;
                            }
                            Thread.sleep(2.msecs);
                        }

                        if (pendingCmdError.length == 0) {
                            results ~= LineResult(lineNo, parsed.commandId, true, "");
                        } else {
                            anyError = true;
                            results ~= LineResult(lineNo, parsed.commandId, false,
                                                  pendingCmdError);
                            if (!continueOnError) break outer;
                        }
                    } catch (Exception e) {
                        anyError = true;
                        results ~= LineResult(lineNo, "", false, e.msg);
                        if (!continueOnError) break outer;
                    }
                }

                // Build JSON response
                Appender!string sb;
                sb.put(`{"status":"`);
                sb.put(anyError ? "error" : "ok");
                sb.put(`","results":[`);
                foreach (i, r; results) {
                    if (i > 0) sb.put(',');
                    sb.put(format(`{"line":%d,"command":"%s","status":"%s"`,
                                  r.lineNo,
                                  r.command.replace("\"", "\\\""),
                                  r.ok ? "ok" : "error"));
                    if (!r.ok && r.message.length > 0) {
                        sb.put(`,"message":"`);
                        sb.put(r.message.replace("\\", "\\\\").replace("\"", "\\\""));
                        sb.put('"');
                    }
                    sb.put('}');
                }
                sb.put("]}");

                response.statusCode = 200;
                response.body = sb.data;
            }
            response.headers["Content-Type"] = "application/json";
        } else if ((request.path == "/api/undo" || request.path == "/api/redo")
                   && request.method == "POST") {
            // Same main-thread sync pattern as /api/command: HTTP thread
            // sets pendingUndoIsRedo, bumps undoSubmittedEpoch, spins on
            // undoCompletedEpoch. tickUndo() on main thread invokes the
            // handler and writes pendingUndoResult.
            bool isRedo = (request.path == "/api/redo");
            auto handler = isRedo ? redoHandler : undoHandler;
            if (handler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"`
                                ~ (isRedo ? "redo" : "undo")
                                ~ ` handler not set"}`;
            } else {
                pendingUndoIsRedo = isRedo;
                pendingUndoResult = false;
                long my = atomicOp!"+="(undoSubmittedEpoch, 1);
                enum int maxIters = 2500;
                int iters = 0;
                while (atomicLoad(undoCompletedEpoch) < my) {
                    if (++iters > maxIters) break;
                    Thread.sleep(2.msecs);
                }
                response.statusCode = 200;
                response.body = pendingUndoResult
                    ? `{"status":"ok"}`
                    : `{"status":"noop","message":"stack empty or revert failed"}`;
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/refire" && request.method == "POST") {
            if (refireHandler is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"refire handler not set"}`;
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("action" !in j || j["action"].type != JSONType.string)
                        throw new Exception("missing 'action' string field");
                    string action = j["action"].str;
                    if (action != "begin" && action != "end")
                        throw new Exception("'action' must be 'begin' or 'end'");
                    pendingRefireAction = action;
                    pendingRefireError  = "";
                    long my = atomicOp!"+="(refireSubmittedEpoch, 1);
                    enum int maxIters = 2500;
                    int iters = 0;
                    while (atomicLoad(refireCompletedEpoch) < my) {
                        if (++iters > maxIters) {
                            pendingRefireError = "timeout waiting for main thread";
                            break;
                        }
                        Thread.sleep(2.msecs);
                    }
                    if (pendingRefireError.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"ok"}`;
                    } else {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"`
                                        ~ pendingRefireError.replace("\"", "\\\"") ~ `"}`;
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                    ~ e.msg.replace("\"", "\\\"") ~ `"}`;
                }
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history" && request.method == "GET") {
            if (historyProvider is null) {
                response.statusCode = 200;
                response.body = `{"undo":[],"redo":[]}`;
            } else {
                response.statusCode = 200;
                response.body = historyProvider();
            }
            response.headers["Content-Type"] = "application/json";
        } else if (request.path == "/api/history/replay" && request.method == "POST") {
            // Re-execute the argstring of undoStack[index] against the current
            // mesh state. Reuses the same main-thread bridge as /api/command —
            // the result is a brand-new history entry; the original is untouched.
            //
            // Caveats (by design, not bugs):
            //  - Replay executes against the CURRENT mesh/selection state, not
            //    the state at the time the original command ran. If the original
            //    bevel targeted edge 5 but the selection has since changed, the
            //    replay hits the current selection. This matches MODO behaviour.
            //  - Selection state is not stored per entry; if the replayed command
            //    depends on selection (e.g. vert.merge), the caller must re-select
            //    before calling this endpoint.
            if (replayProvider is null) {
                response.statusCode = 200;
                response.body = `{"status":"error","message":"replay provider not set"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                try {
                    auto j = parseJSON(request.body);
                    if ("index" !in j ||
                        (j["index"].type != JSONType.integer &&
                         j["index"].type != JSONType.uinteger))
                        throw new Exception("missing 'index' integer field");

                    long idx = (j["index"].type == JSONType.integer)
                               ? j["index"].integer
                               : cast(long)j["index"].uinteger;
                    if (idx < 0) throw new Exception("'index' must be non-negative");

                    string line = replayProvider(cast(size_t)idx);
                    if (line.length == 0) {
                        response.statusCode = 200;
                        response.body = `{"status":"error","message":"no entry at given index"}`;
                    } else {
                        // Parse the line and dispatch through the existing
                        // main-thread bridge — identical path to argstring /api/command.
                        auto parsed = parseArgstring(line);
                        if (parsed.isEmpty)
                            throw new Exception("entry parsed as empty");
                        pendingCmdId     = parsed.commandId;
                        pendingCmdParams = parsed.params.toString();
                        pendingCmdError  = "";
                        long my = atomicOp!"+="(submittedEpoch, 1);
                        enum int maxIters = 2500;  // 2500 * 2ms = ~5s
                        int iters = 0;
                        while (atomicLoad(completedEpoch) < my) {
                            if (++iters > maxIters) {
                                pendingCmdError = "timeout waiting for main thread";
                                break;
                            }
                            Thread.sleep(2.msecs);
                        }
                        if (pendingCmdError.length == 0) {
                            response.statusCode = 200;
                            response.body = `{"status":"ok","line":"`
                                          ~ line.replace("\\", "\\\\").replace("\"", "\\\"")
                                          ~ `"}`;
                        } else {
                            response.statusCode = 200;
                            response.body = `{"status":"error","message":"`
                                          ~ pendingCmdError.replace("\\", "\\\\").replace("\"", "\\\"")
                                          ~ `"}`;
                        }
                    }
                } catch (Exception e) {
                    response.statusCode = 200;
                    response.body = `{"status":"error","message":"`
                                  ~ e.msg.replace("\\", "\\\\").replace("\"", "\\\"") ~ `"}`;
                }
                response.headers["Content-Type"] = "application/json";
            }
        } else if (request.path == "/api/play-events" && request.method == "POST") {
            if (!testMode) {
                response.statusCode = 403;
                response.body = `{"error":"play-events is only available in --test mode"}`;
                response.headers["Content-Type"] = "application/json";
            } else if (eventPlayer.load(request.body) && eventPlayer.entries.length > 0) {
                response.statusCode = 200;
                response.body = `{"status": "success", "message": "Events loaded successfully"}`;
                response.headers["Content-Type"] = "application/json";
            } else {
                response.statusCode = 400;
                response.body = `{"status": "error", "message": "Failed to parse events"}`;
                response.headers["Content-Type"] = "application/json";
            }
        } else {
            response.statusCode = 404;
            response.body = "<html><body><h1>404 Not Found</h1><p>The requested resource was not found.</p></body></html>";
            response.headers["Content-Type"] = "text/html";
        }

        return response;
    }

    /**
     * Format an HTTP response
     */
    private string formatResponse(HttpResponse response) {
        string statusLine;
        switch (response.statusCode) {
            case 200: statusLine = "HTTP/1.1 200 OK"; break;
            case 400: statusLine = "HTTP/1.1 400 Bad Request"; break;
            case 404: statusLine = "HTTP/1.1 404 Not Found"; break;
            case 500: statusLine = "HTTP/1.1 500 Internal Server Error"; break;
            default: statusLine = "HTTP/1.1 " ~ to!string(response.statusCode) ~ " Unknown";
        }

        string headers = "";
        foreach (key, value; response.headers) {
            headers ~= key ~ ": " ~ value ~ "\r\n";
        }
        headers ~= "Content-Length: " ~ to!string(response.body.length) ~ "\r\n";
        headers ~= "\r\n";

        return statusLine ~ "\r\n" ~ headers ~ response.body;
    }

    /**
     * Tick the event player — call once per frame from the main loop
     * for time-based playback of a previously loaded event log.
     */
    public bool tickEventPlayer() {
        return eventPlayer.tick();
    }

    /**
     * Tick reset — call once per frame from the main loop.
     * Drains a pending /api/reset request synchronously so that the HTTP
     * thread waiting on the reset can return only after state is rebuilt.
     */
    public void tickReset() {
        long sub = atomicLoad(resetSubmittedEpoch);
        long cmp = atomicLoad(resetCompletedEpoch);
        if (sub <= cmp) return;
        if (resetHandler !is null) resetHandler(resetPendingType, resetPendingEmpty);
        atomicStore(resetCompletedEpoch, sub);
    }

    /**
     * Tick command — call once per frame from the main loop.
     * Drains a pending /api/command request: dispatches via commandHandler,
     * captures any thrown error message, and bumps completedEpoch so the
     * waiting HTTP thread can return a response.
     */
    public void tickCommand() {
        long sub = atomicLoad(submittedEpoch);
        long cmp = atomicLoad(completedEpoch);
        if (sub <= cmp) return;
        if (commandHandler is null) {
            pendingCmdError = "command handler not set";
        } else {
            try {
                commandHandler(pendingCmdId, pendingCmdParams);
                pendingCmdError = "";
            } catch (Exception e) {
                pendingCmdError = e.msg;
            }
        }
        atomicStore(completedEpoch, sub);
    }

    /**
     * Tick transform — same pattern as tickCommand, for /api/transform.
     */
    public void tickTransform() {
        long sub = atomicLoad(xfSubmittedEpoch);
        long cmp = atomicLoad(xfCompletedEpoch);
        if (sub <= cmp) return;
        if (transformHandler is null) {
            pendingXfError = "transform handler not set";
        } else {
            try {
                transformHandler(pendingXfKind, pendingXfParams);
                pendingXfError = "";
            } catch (Exception e) {
                pendingXfError = e.msg;
            }
        }
        atomicStore(xfCompletedEpoch, sub);
    }

    /// Tick camera-set — same pattern as tickTransform, for POST /api/camera.
    public void tickCameraSet() {
        long sub = atomicLoad(camSetSubmittedEpoch);
        long cmp = atomicLoad(camSetCompletedEpoch);
        if (sub <= cmp) return;
        if (cameraSetHandler is null) {
            pendingCamSetError = "camera-set handler not set";
        } else {
            try {
                cameraSetHandler(pendingCamSet);
                pendingCamSetError = "";
            } catch (Exception e) {
                pendingCamSetError = e.msg;
            }
        }
        atomicStore(camSetCompletedEpoch, sub);
    }

    /**
     * Tick selection — same pattern as tickCommand, for /api/select.
     */
    public void tickSelection() {
        long sub = atomicLoad(selSubmittedEpoch);
        long cmp = atomicLoad(selCompletedEpoch);
        if (sub <= cmp) return;
        if (selectionHandler is null) {
            pendingSelError = "selection handler not set";
        } else {
            try {
                selectionHandler(pendingSelMode, pendingSelIndices);
                pendingSelError = "";
            } catch (Exception e) {
                pendingSelError = e.msg;
            }
        }
        atomicStore(selCompletedEpoch, sub);
    }

    /**
     * Tick refire — same main-thread sync pattern as the others.
     */
    public void tickRefire() {
        long sub = atomicLoad(refireSubmittedEpoch);
        long cmp = atomicLoad(refireCompletedEpoch);
        if (sub <= cmp) return;
        if (refireHandler is null) {
            pendingRefireError = "refire handler not set";
        } else {
            try {
                refireHandler(pendingRefireAction);
                pendingRefireError = "";
            } catch (Exception e) {
                pendingRefireError = e.msg;
            }
        }
        atomicStore(refireCompletedEpoch, sub);
    }

    /**
     * Tick undo/redo — same main-thread sync pattern as the others.
     */
    public void tickUndo() {
        long sub = atomicLoad(undoSubmittedEpoch);
        long cmp = atomicLoad(undoCompletedEpoch);
        if (sub <= cmp) return;
        auto h = pendingUndoIsRedo ? redoHandler : undoHandler;
        if (h is null) {
            pendingUndoResult = false;
        } else {
            try {
                pendingUndoResult = h();
            } catch (Exception) {
                pendingUndoResult = false;
            }
        }
        atomicStore(undoCompletedEpoch, sub);
    }

    /**
     * Check if the server is currently running
     */
    public bool running() const {
        return isRunning;
    }

    /**
     * Get the port the server is running on
     */
    public ushort getPort() const {
        return port;
    }
}

/**
 * Simple HTTP request representation
 */
class HttpRequest {
    public string method;
    public string path;
    public string httpVersion;
    public string[string] headers;
    public string body;

    public this(string method, string path, string httpVersion) {
        this.method = method;
        this.path = path;
        this.httpVersion = httpVersion;
        this.headers = new string[string];
    }
}

/**
 * Simple HTTP response representation
 */
class HttpResponse {
    public int statusCode;
    public string[string] headers;
    public string body;

    public this() {
        this.statusCode = 200;
        this.headers = new string[string];
        this.headers["Server"] = "Vibe3D-HTTP-Server/1.0";
        this.headers["Connection"] = "close";
        this.body = "";
    }
}

// Parse `?key=N` (or `&key=N`) from a request path. Returns `def` when the
// key is missing or not parseable as int.
private int parseQueryInt(string path, string key, int def) {
    import std.conv : to, ConvException;
    auto qi = path.indexOf('?');
    if (qi < 0) return def;
    foreach (kv; path[qi + 1 .. $].split('&')) {
        auto eq = kv.indexOf('=');
        if (eq < 0) continue;
        if (kv[0 .. eq] == key) {
            try return kv[eq + 1 .. $].to!int;
            catch (ConvException) return def;
        }
    }
    return def;
}

// Parse `?key=str` (or `&key=str`) from a request path. Returns `def` when
// the key is missing.
private string parseQueryString(string path, string key, string def) {
    auto qi = path.indexOf('?');
    if (qi < 0) return def;
    foreach (kv; path[qi + 1 .. $].split('&')) {
        auto eq = kv.indexOf('=');
        if (eq < 0) continue;
        if (kv[0 .. eq] == key) return kv[eq + 1 .. $].idup;
    }
    return def;
}

/**
 * Convert mesh data to JSON string
 */
string meshToJson(size_t vertexCount, size_t edgeCount, size_t faceCount) {
    import std.format : format;
    string res = format("{\"vertexCount\": %d, \"edgeCount\": %d, \"faceCount\": %d, \"timestamp\": \"%s\"}",
                  vertexCount, edgeCount, faceCount, Clock.currTime.toISOExtString());
    return res;
}

/**
 * Convert detailed mesh data to JSON string
 */
string meshToJsonDetailed(size_t vertexCount, size_t edgeCount, size_t faceCount,
                          float[] vertices, uint[2][] edges,
                          uint[][] faces, bool[] isSubpatch) {
    import std.format : format;
    import std.array : appender;
    import std.string : join;

    auto json = appender!string();
    json ~= "{";
    json ~= format("\"vertexCount\": %d, ", vertexCount);
    json ~= format("\"edgeCount\": %d, ", edgeCount);
    json ~= format("\"faceCount\": %d, ", faceCount);
    json ~= format("\"timestamp\": \"%s\", ", Clock.currTime.toISOExtString());

    // Add vertices array
    json ~= "\"vertices\": [";
    for (size_t i = 0; i < vertices.length; i += 3) {
        if (i > 0) json ~= ", ";
        json ~= format("[%f, %f, %f]", vertices[i], vertices[i+1], vertices[i+2]);
    }
    json ~= "], ";

    // Add edges array (each edge as a 2-element [a, b] vertex-index pair)
    json ~= "\"edges\": [";
    for (size_t i = 0; i < edges.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= format("[%d, %d]", edges[i][0], edges[i][1]);
    }
    json ~= "], ";

    // Add faces array
    json ~= "\"faces\": [";
    for (size_t i = 0; i < faces.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= "[";
        for (size_t j = 0; j < faces[i].length; ++j) {
            if (j > 0) json ~= ", ";
            json ~= format("%d", faces[i][j]);
        }
        json ~= "]";
    }
    json ~= "], ";

    // Add per-face subpatch flags (parallel to faces[]).
    json ~= "\"isSubpatch\": [";
    for (size_t i = 0; i < isSubpatch.length; ++i) {
        if (i > 0) json ~= ", ";
        json ~= isSubpatch[i] ? "true" : "false";
    }
    json ~= "]";
    json ~= "}";

    return json.data;
}