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
    private alias DetailedModelDataProvider = string delegate(float[], uint[][]);
    private DetailedModelDataProvider detailedModelDataProvider;
    private bool useDetailedProvider = false;
    private float[] meshVertices;
    private uint[][] meshFaces;

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
    public void setDetailedModelDataProvider(DetailedModelDataProvider provider, float[] vertices, uint[][] faces) {
        this.detailedModelDataProvider = provider;
        this.meshVertices = vertices;
        this.meshFaces = faces;
        this.useDetailedProvider = true;
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
            char[4096] buffer;
            size_t received = client.receive(buffer[]);

            if (received > 0) {
                string request = buffer[0 .. received].idup;
                stderr.writeln("Received request: ", request.split("\n")[0]);

                // Parse the HTTP request
                HttpRequest httpRequest = parseRequest(request);
                HttpResponse response = handleRequest(httpRequest);

                // Send the response
                string responseStr = formatResponse(response);
                client.send(responseStr);
            }
        } catch (Exception e) {
            stderr.writeln("Error handling client: ", e.msg);
        } finally {
            client.close();
        }
    }

    /**
     * Parse an HTTP request
     */
    private HttpRequest parseRequest(string request) {
        auto lines = request.split("\n");
        if (lines.length == 0) {
            return new HttpRequest("GET", "/", "HTTP/1.1");
        }

        auto requestLine = lines[0].strip();
        auto parts = requestLine.split(' ');

        string method = "GET";
        string path = "/";
        string httpVersion = "HTTP/1.1";

        if (parts.length >= 1) method = parts[0];
        if (parts.length >= 2) path = parts[1];
        if (parts.length >= 3) httpVersion = parts[2];

        auto httpRequest = new HttpRequest(method, path, httpVersion);

        // Parse headers and body
        bool headersDone = false;
        string[] headerLines;
        string body;

        foreach (i, line; lines) {
            if (i == 0) continue; // Skip request line

            string strippedLine = line.strip();
            if (strippedLine.length == 0) {
                headersDone = true;
                continue;
            }

            if (!headersDone) {
                headerLines ~= strippedLine;
            } else {
                body ~= strippedLine ~ "\n";
            }
        }

        // Parse headers
        foreach (headerLine; headerLines) {
            auto colonPos = headerLine.indexOf(":");
            if (colonPos > 0) {
                string key = headerLine[0 .. colonPos].strip();
                string value = headerLine[colonPos + 1 .. $].strip();
                httpRequest.headers[key] = value;
            }
        }

        // Set body (remove trailing newline if present)
        if (body.length > 0 && body[$-1] == '\n') {
            body = body[0 .. $-1];
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
                           "<li>/api/model - Get current model state</li></ul>" ~
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
                    response.body = detailedModelDataProvider(meshVertices, meshFaces);
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
        } else if (request.path == "/api/play-events" && request.method == "POST") {
            if (eventPlayer.load(request.body) && eventPlayer.entries.length > 0) {
                // Set startCounter to 0 so all events appear elapsed (immediate playback)
                eventPlayer.startCounter = 0;
                eventPlayer.tick();
                response.statusCode = 200;
                response.body = `{"status": "success", "message": "Events played successfully"}`;
            } else {
                response.statusCode = 400;
                response.body = `{"status": "error", "message": "Failed to parse events"}`;
            }
            response.headers["Content-Type"] = "application/json";
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
string meshToJsonDetailed(size_t vertexCount, size_t edgeCount, size_t faceCount, float[] vertices, uint[][] faces) {
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
    json ~= "]";
    json ~= "}";

    return json.data;
}