// workplane.* command tests (Stage C1 of doc/test_coverage_plan.md).
//
// Exercises the five MODO-aligned workplane commands:
//   workplane.reset                               — back to auto, origin, no rotation
//   workplane.edit cenX:N cenY:N cenZ:N rotX:N rotY:N rotZ:N
//   workplane.rotate axis:X|Y|Z angle:N           — delta rotation
//   workplane.offset axis:X|Y|Z dist:N            — delta translation
//   workplane.alignToSelection                    — derive from polygon selection
//
// State is read back from the WORK stage's listAttrs via /api/toolpipe.

import std.net.curl;
import std.json;
import std.math : fabs;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void runCmd(string argstring) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

string[string] workplaneAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WORK") {
            string[string] m;
            foreach (k, v; st["attrs"].object) m[k] = v.str;
            return m;
        }
    }
    assert(false, "WORK stage not found in /api/toolpipe");
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

double f(string[string] a, string key) { return a[key].to!double; }

unittest { // reset: auto=true, center=0, rotation=0
    post(baseUrl ~ "/api/reset", "");
    // Knock workplane out of default first so reset has work to do.
    runCmd("workplane.offset axis:X dist:0.7");
    runCmd("workplane.rotate axis:Y angle:45");
    auto pre = workplaneAttrs();
    assert(!approx(f(pre, "cenX"), 0.0) || !approx(f(pre, "rotY"), 0.0),
        "setup: workplane should be non-default before reset");

    runCmd("workplane.reset");
    auto a = workplaneAttrs();
    assert(a["auto"] == "true", "reset did not restore auto, got " ~ a["auto"]);
    assert(approx(f(a, "cenX"), 0.0) && approx(f(a, "cenY"), 0.0) && approx(f(a, "cenZ"), 0.0),
        "reset did not zero center: (" ~ a["cenX"] ~ "," ~ a["cenY"] ~ "," ~ a["cenZ"] ~ ")");
    assert(approx(f(a, "rotX"), 0.0) && approx(f(a, "rotY"), 0.0) && approx(f(a, "rotZ"), 0.0),
        "reset did not zero rotation: (" ~ a["rotX"] ~ "," ~ a["rotY"] ~ "," ~ a["rotZ"] ~ ")");
}

unittest { // offset adds dist along the chosen axis; subsequent offsets stack
    post(baseUrl ~ "/api/reset", "");
    runCmd("workplane.offset axis:X dist:0.3");
    auto a1 = workplaneAttrs();
    assert(approx(f(a1, "cenX"), 0.3),
        "after offset X 0.3, cenX should be 0.3; got " ~ a1["cenX"]);

    runCmd("workplane.offset axis:Y dist:-1.5");
    auto a2 = workplaneAttrs();
    assert(approx(f(a2, "cenX"), 0.3),
        "Y offset shouldn't disturb cenX: " ~ a2["cenX"]);
    assert(approx(f(a2, "cenY"), -1.5),
        "after offset Y -1.5, cenY should be -1.5; got " ~ a2["cenY"]);

    runCmd("workplane.offset axis:X dist:0.7");  // stacks
    auto a3 = workplaneAttrs();
    assert(approx(f(a3, "cenX"), 1.0),
        "stacked X offset 0.3+0.7 should yield cenX=1.0; got " ~ a3["cenX"]);
}

unittest { // rotate adds angle (degrees) around the chosen axis; stacks
    post(baseUrl ~ "/api/reset", "");
    runCmd("workplane.rotate axis:Y angle:30");
    auto a1 = workplaneAttrs();
    assert(approx(f(a1, "rotY"), 30.0),
        "after rotate Y 30, rotY should be 30; got " ~ a1["rotY"]);
    assert(a1["auto"] == "false",
        "explicit rotate should turn auto off; got " ~ a1["auto"]);

    runCmd("workplane.rotate axis:Y angle:15");  // stacks
    auto a2 = workplaneAttrs();
    assert(approx(f(a2, "rotY"), 45.0),
        "stacked rotate 30+15 should yield rotY=45; got " ~ a2["rotY"]);
}

unittest { // edit: absolute set, NaN fields untouched
    post(baseUrl ~ "/api/reset", "");
    runCmd("workplane.offset axis:Z dist:9");      // baseline non-zero cenZ
    runCmd("workplane.edit cenX:1 rotZ:90");        // touches only cenX and rotZ
    auto a = workplaneAttrs();
    assert(approx(f(a, "cenX"), 1.0),  "edit cenX:1 → cenX=1, got " ~ a["cenX"]);
    assert(approx(f(a, "cenZ"), 9.0),  "edit shouldn't clobber cenZ: " ~ a["cenZ"]);
    assert(approx(f(a, "rotZ"), 90.0), "edit rotZ:90 → rotZ=90, got " ~ a["rotZ"]);
    assert(a["auto"] == "false",
        "edit with rotation field should turn auto off");
}

unittest { // alignToSelection on top face: workplane center sits at face centroid
    post(baseUrl ~ "/api/reset", "");
    // Find top face index — same approach as test_tool_rotate_drag.
    auto m = getJson("/api/model");
    int topFace = -1;
    foreach (fi, f_; m["faces"].array) {
        bool top = true;
        foreach (vi; f_.array)
            if (fabs(m["vertices"].array[vi.integer].array[1].floating - 0.5) > 1e-4)
                { top = false; break; }
        if (top) { topFace = cast(int)fi; break; }
    }
    assert(topFace >= 0, "no top face on default cube");

    post(baseUrl ~ "/api/select",
        `{"mode":"polygons","indices":[` ~ topFace.to!string ~ `]}`);
    runCmd("workplane.alignToSelection");

    auto a = workplaneAttrs();
    // Top-face centroid sits at (0, 0.5, 0).
    assert(approx(f(a, "cenX"), 0.0) && approx(f(a, "cenY"), 0.5) && approx(f(a, "cenZ"), 0.0),
        "alignToSelection should set center to top-face centroid (0,0.5,0); got (" ~
        a["cenX"] ~ "," ~ a["cenY"] ~ "," ~ a["cenZ"] ~ ")");
    assert(a["auto"] == "false",
        "alignToSelection pins the workplane (auto=false); got " ~ a["auto"]);
}
