// The suite's HTTP client reuses one connection per thread (task 9461): the
// shared client asks for keep-alive and the server honours it, so a repeated
// request opens no new TCP connection. A fresh std.net.curl handle is the
// control that must open one.

import http_client : getJson, keepAliveConnection, keepAliveGet,
    keepAlivePost, postRaw, testBaseUrl;
import core.thread : Thread;
import etc.c.curl : CurlInfo;
import std.conv : to;
import std.net.curl : HTTP, get;

void main() {}

/// A long-valued libcurl info of the handle's last transfer. getTiming is the
/// only public door and writes the C `long` into a double's storage, so it
/// is read back through a union.
long info(HTTP http, CurlInfo which) {
    union Slot { double asDouble; long asLong; }
    Slot slot;
    http.handle.getTiming(which, slot.asDouble);
    return slot.asLong;
}

/// Run `call` twice on a NEW thread (so its thread-local connection starts
/// unused) and report the shared handle's last transfer: "<code>/<connects>".
/// A function that bypassed the handle leaves code 0.
string secondTransfer(void delegate() call) {
    string seen;
    auto t = new Thread({
        call();
        call();
        auto http = keepAliveConnection();
        seen = info(http, CurlInfo.response_code).to!string ~ "/"
            ~ info(http, CurlInfo.num_connects).to!string;
    });
    t.start();
    t.join();
    return seen;
}

unittest {
    auto fresh = HTTP();
    get(testBaseUrl ~ "/api/camera", fresh);
    get(testBaseUrl ~ "/api/camera", fresh);
    immutable control = info(fresh, CurlInfo.num_connects);
    assert(control == 1,
        "9461 control: a handle without keep-alive must open a connection per "
        ~ "request; got " ~ control.to!string);

    immutable viaGetJson = secondTransfer({ getJson("/api/camera"); });
    immutable viaPostRaw = secondTransfer({ postRaw("/api/trace/disarm", ""); });
    immutable viaGet = secondTransfer({ keepAliveGet(testBaseUrl ~ "/api/camera"); });
    immutable viaPost = secondTransfer({
        keepAlivePost(testBaseUrl ~ "/api/trace/disarm", ""); });
    assert(viaGetJson == "200/0" && viaPostRaw == "200/0"
        && viaGet == "200/0" && viaPost == "200/0",
        "9461 reuse: a repeated request did not ride the shared keep-alive "
        ~ "connection (code/connects): getJson " ~ viaGetJson ~ ", postRaw "
        ~ viaPostRaw ~ ", keepAliveGet " ~ viaGet ~ ", keepAlivePost " ~ viaPost);
}
