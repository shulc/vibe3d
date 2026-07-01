import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

JSONValue postJson(string path, string body) {
    auto resp = cast(string)post("http://localhost:8080" ~ path, body);
    return parseJSON(resp);
}

void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void assertCameraJson(JSONValue j, string ctx) {
    assert("azimuth"   in j, ctx ~ ": missing 'azimuth'");
    assert("elevation" in j, ctx ~ ": missing 'elevation'");
    assert("distance"  in j, ctx ~ ": missing 'distance'");
}

unittest {
    // Reset to clean state.
    auto resetResp = postJson("/api/reset", "{}");
    assert(resetResp["status"].str == "ok", "reset failed");

    // /api/camera with no param returns the active cell's camera.
    {
        auto j = parseJSON(cast(string)get("http://localhost:8080/api/camera"));
        assertCameraJson(j, "GET /api/camera (no param)");
    }

    // /api/camera?viewport=0 — explicit cell 0.
    {
        auto j = parseJSON(cast(string)get("http://localhost:8080/api/camera?viewport=0"));
        assertCameraJson(j, "GET /api/camera?viewport=0");
    }

    // Switch to Quad layout and verify all 4 cells are reachable.
    runCmd(`{"id":"viewport.layout","params":"Quad"}`);

    foreach (k; 0 .. 4) {
        auto j = parseJSON(cast(string)get(
            "http://localhost:8080/api/camera?viewport=" ~ k.to!string));
        assertCameraJson(j, "GET /api/camera?viewport=" ~ k.to!string ~ " (Quad)");
    }

    // Out-of-range index falls back to active cell (no crash, valid JSON).
    {
        auto j = parseJSON(cast(string)get("http://localhost:8080/api/camera?viewport=99"));
        assertCameraJson(j, "GET /api/camera?viewport=99 (out-of-range fallback)");
    }

    // Switch back to Single and verify cell 0 still works.
    runCmd(`{"id":"viewport.layout","params":"Single"}`);

    {
        auto j = parseJSON(cast(string)get("http://localhost:8080/api/camera?viewport=0"));
        assertCameraJson(j, "GET /api/camera?viewport=0 (back to Single)");
    }
}
