// The HTTP layer's error bodies must be JSON — even when the message they
// carry contains a character JSON has an opinion about (audit №4, D11).
//
// WHY THIS IS A LIVE BUG AND NOT HYGIENE. `http_server.d` assembles most of
// its error bodies by concatenation, and 45 of its 49 escape sites replaced
// the double quote and nothing else. The messages they interpolate are not
// constants: `unknown layer kind 'X'`, `unknown command id 'X'`, a failed
// load's file path. One backslash in X and the body stops being JSON:
//
//   {"status":"error","message":"unknown layer kind 'a\zb'"}
//                                                    ^^ not an escape
//
// A client sees a parse error, not the error the server was trying to report,
// which is the worst possible moment to lose the message.
//
// WHY `\z` AND NOT `\b`. `\b` IS a valid JSON escape (backspace), so a body
// carrying it still parses — it just silently decodes to different text than
// the server meant. A test built on `\b` would pass against the broken
// escaper as long as it only checked parseability. `\z` is a hard parse
// error, and asserting the round-tripped TEXT catches the `\b` class too, so
// both are checked below.
//
// The endpoint is `/api/test/layer` because it is the shortest path from a
// request body to an exception message that quotes it back: an unknown kind
// token throws `unknown layer kind '<token>'`, and the token is whatever the
// request said.

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.algorithm : canFind;

void main() {}

alias baseUrl = testBaseUrl;

// POST that tolerates a non-2xx status — an error body is the thing under
// test, so `post` throwing on 500 would hide it.
private string postRaw(string path, string body_) {
    auto http = HTTP();
    http.method = HTTP.Method.post;
    http.url = baseUrl ~ path;
    http.addRequestHeader("Content-Type", "application/json");
    http.setPostData(body_, "application/json");
    string resp;
    http.onReceive = (ubyte[] data) { resp ~= cast(string)data; return data.length; };
    http.onReceiveStatusLine = (HTTP.StatusLine) {};   // never throw on 4xx/5xx
    http.perform();
    return resp;
}

// One round: send `kindToken` as the layer kind, expect a refusal whose
// message quotes the token back VERBATIM inside valid JSON.
private void checkKind(string kindToken, string label) {
    auto reqBody = JSONValue(["kind": JSONValue(kindToken)]).toString();
    string raw = postRaw("/api/test/layer", reqBody);

    JSONValue j;
    try {
        j = parseJSON(raw);
    } catch (Exception e) {
        assert(false, label ~ ": response body is not JSON (" ~ e.msg
                      ~ ") — raw was: " ~ raw);
    }

    // The refusal itself: an unknown kind must not be accepted.
    assert("status" !in j || j["status"].str != "ok",
           label ~ ": an unknown kind was ACCEPTED — " ~ raw);

    // And the message must carry the token unmangled. This is the half that
    // catches a `\b`-style silent re-decode, which parses fine.
    string msg;
    if      ("message" in j) msg = j["message"].str;
    else if ("error"   in j) msg = j["error"].str;
    else assert(false, label ~ ": error body has neither message nor error — " ~ raw);

    assert(msg.canFind(kindToken),
           label ~ ": the message lost or re-decoded the token; wanted "
           ~ kindToken ~ " inside " ~ msg);
}

unittest {
    // Backslash + a letter that is NOT a JSON escape: breaks parsing outright.
    checkKind(`a\zb`, "backslash-z");

    // Backslash + a letter that IS a JSON escape: parses either way, so only
    // the round-tripped text separates a correct escaper from a broken one.
    checkKind(`a\bz`, "backslash-b");

    // A quote — the ONE character the old hand-rolled escape did handle.
    // Kept so the fix cannot regress the case that used to work.
    checkKind(`a"b`, "quote");

    // A newline. Raw control characters are illegal inside a JSON string, so
    // this needs the same escaper the two above do.
    checkKind("a\nb", "newline");
}
