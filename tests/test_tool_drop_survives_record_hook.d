// Regression test for task 0678 D9-a's follow-up crash (2026-08-13).
//
// D9-a wired `CommandHistory.recordToolLifecycle` into `history.onRecord` so
// the macro recorder stops missing tool drops. Under `--test` the app chains
// TWO consumers onto that hook (app.d): the macro recorder, and the step-trace
// capture that feeds `/api/trace`. The trace capture ends with
//
//     if (activeTool !is null) entry["tool"] = activeTool.toolStateJson();
//
// under a comment stating the invariant it relies on: "the tool that just
// produced this step is still `activeTool`, with its params untouched".
//
// That invariant is TRUE for the ordinary `record()` path and FALSE for the
// lifecycle one: `recordToolLifecycle` is called from INSIDE setActiveTool's
// drop, after the outgoing tool's `deactivate()` has already released its
// session state — so the hook read `toolStateJson()` off a half-torn-down
// tool and SEGFAULTED the whole app. Every subsequent HTTP test on that
// worker then failed with "Couldn't connect to server" (537 of 597 in CI),
// with nothing in the CI output explaining why.
//
// The fix skips ToolLifecycle entries in the trace capture only (a tool drop
// is not a model step); the macro recorder still receives the line, which is
// what D9-a was for.
//
// This test pins the SURVIVAL contract rather than any trace content: with
// the step trace armed (it always is under `--test`), activating and dropping
// a tool must leave the server answering. It is deliberately transport-level
// — the crash lived in a nested function of app.d's main(), which `dub test`
// does not compile at all.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string) get(baseUrl ~ path)); }

// `/api/tool/state` carries the ACTIVE tool's own state object and is `{}`
// when nothing is armed — there is no "active" flag to read.
bool toolArmed() {
    auto st = getJson("/api/tool/state");
    return st.type == JSONType.object && st.object.length > 0;
}

void cmd(string s) {
    auto resp = post(baseUrl ~ "/api/script", s);
    assert(parseJSON(cast(string) resp)["status"].str == "ok",
        "cmd `" ~ s ~ "` failed: " ~ cast(string) resp);
}

unittest {
    // Baseline: the server answers before we start.
    assert(getJson("/api/ping")["status"].str == "ok", "server must be up");
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);

    // Arm a tool, then drop it — the drop is what records a ToolLifecycle
    // entry and fires the onRecord chain from inside the teardown.
    cmd("tool.set move on");
    assert(toolArmed(), "tool.set move on must arm the tool");

    cmd("tool.set move off");

    // The assertion IS the round-trip: a crashed server cannot answer.
    assert(getJson("/api/ping")["status"].str == "ok",
           "server died dropping a tool — an onRecord consumer read state "
           ~ "that teardown had already released");
    assert(!toolArmed(), "tool.set move off must drop the tool");

    // Same shape via the other drop route: activate, then let a scene reset
    // drop the armed tool (file.new's path, which also records a lifecycle
    // entry) — the server must survive that too.
    cmd("tool.set move on");
    auto r2 = parseJSON(cast(string) post(baseUrl ~ "/api/reset", ""));
    assert(r2["status"].str == "ok", "/api/reset after arming failed");
    assert(getJson("/api/ping")["status"].str == "ok",
           "server died on a reset-driven tool drop");
}
