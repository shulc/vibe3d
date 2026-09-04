// Task 0553 — the `compact` scale handles report a press point.
//
// The gap this closes (found by 0553 phase A, fixed in phase B):
// `ScaleHeadHandle` — the proxy handle the bare `Transform` preset registers
// in place of the scale stem, carrying its own pick tolerance (a disc around
// the axis box, not the stem capsule) — did not override `screenAnchor`.
// `/api/tool/handles` therefore reported `screen: null` for every scale part
// in exactly the preset where scale is grabbed by a rule of its own, so no
// test could ask the product "where do I press to grab scale here?".
//
// Three lanes (0537 / 0540 / 0548) declined to port the scale axis after
// their off-handle presses came back null, and this was phase A's prime
// suspect for at least some of those nulls: a driver that resolves its press
// point through the handles API gets nothing back here and has to fall back
// to a computed guess.
//
// The pin is two-part, and the second part is the one that matters: the
// anchor must not merely be non-null, it must be a pixel that actually grabs
// that handle. Anchor and hit test read the same point (`target.end`), so
// hovering the anchor must make that exact part hot.

import http_client : testBaseUrl;
import std.format : format;
import std.json;
import std.net.curl : get, post;

import drag_helpers : playAndWait;

void main() {}

alias baseUrl = testBaseUrl;

private JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

// Registration bases from source/tools/transform/xfrm_transform.d — scale
// occupies 20..29, one part per axis head in the compact presentation.
private enum int SCALE_BASE = 20;

private string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

unittest {
    postJson("/api/reset", "");
    postJson("/api/select",
        `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    // The bare preset — T+R+S in one bank, which is the presentation that
    // swaps the scale stems for ScaleHeadHandle proxies.
    postJson("/api/script", "tool.set Transform");

    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles.type != JSONType.null_,
           "compact Transform registered no arbiter handles at all");

    // 1. Every registered scale part must carry an anchor. Before the fix
    //    each of these was `screen: null`.
    int seen = 0;
    double ax = 0, ay = 0;
    int    axPart = -1;
    foreach (p; handles["parts"].array) {
        int part = cast(int)p["part"].integer;
        if (part < SCALE_BASE || part >= SCALE_BASE + 10) continue;
        if (!p["visible"].boolean) continue;
        ++seen;
        assert(p["screen"].type != JSONType.null_,
               format("scale part %d reports screen:null — the compact "
                      ~ "presentation has no introspectable press point for "
                      ~ "scale again (ScaleHeadHandle.screenAnchor)", part));
        if (axPart < 0) {
            auto s = p["screen"].array;
            ax = s[0].floating;
            ay = s[1].floating;
            axPart = part;
        }
    }
    assert(seen >= 1,
           "compact Transform registered no visible scale parts — the part "
           ~ "numbering or the preset changed, not just the anchor");

    // 2. The anchor must be a pixel that GRABS that part, not merely a
    //    projected world point. Hovering it must make that exact part hot;
    //    a bare projection with no relation to the hit region would land
    //    on some neighbour, or on nothing.
    auto cam = getJson("/api/camera");
    playAndWait(hoverLog(cast(int)cam["vpX"].integer,
                         cast(int)cam["vpY"].integer,
                         cast(int)cam["width"].integer,
                         cast(int)cam["height"].integer,
                         cast(int)ax, cast(int)ay));

    auto after = getJson("/api/tool/handles")["handles"];
    int hot = cast(int)after["hot"].integer;
    assert(hot == axPart,
           format("hovering scale part %d's own anchor (%.1f, %.1f) made "
                  ~ "part %d hot instead — the anchor is not a press point "
                  ~ "for the handle that published it", axPart, ax, ay, hot));
}
