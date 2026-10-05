// The suite's HTTP client reuses one connection per thread (task 9461): the
// shared client asks for keep-alive and the server honours it, so a second
// request opens no new TCP connection. A fresh std.net.curl handle is the
// control that must open one.

import http_client : getJson, keepAliveConnection, keepAliveGet, testBaseUrl;
import etc.c.curl : CurlInfo;
import std.conv : to;
import std.net.curl : HTTP, get;

void main() {}

/// Connections libcurl opened for the handle's last transfer. The info is a
/// C `long`; getTiming is the only public door and writes it into a double's
/// storage, so it is read back through a union.
long connectsOfLastTransfer(HTTP http) {
    union Info { double asDouble; long asLong; }
    Info info;
    http.handle.getTiming(CurlInfo.num_connects, info.asDouble);
    return info.asLong;
}

unittest {
    getJson("/api/camera");
    getJson("/api/camera");
    immutable reused = connectsOfLastTransfer(keepAliveConnection());
    keepAliveGet(testBaseUrl ~ "/api/camera");
    immutable reusedAgain = connectsOfLastTransfer(keepAliveConnection());

    auto fresh = HTTP();
    get(testBaseUrl ~ "/api/camera", fresh);
    get(testBaseUrl ~ "/api/camera", fresh);
    immutable control = connectsOfLastTransfer(fresh);

    assert(control == 1,
        "9461 control: a handle without keep-alive must open a connection per "
        ~ "request; got " ~ control.to!string);
    assert(reused == 0 && reusedAgain == 0,
        "9461 reuse: the shared client opened a connection for a repeated "
        ~ "request (getJson " ~ reused.to!string ~ ", keepAliveGet "
        ~ reusedAgain.to!string ~ ")");
}
