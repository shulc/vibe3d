// `/api/viewport/probe` point sampling reads the framebuffer ONCE per request
// (card slot-resource-isolation). A per-point glReadPixels is one GPU round
// trip each; on a shared GPU a 3000-point lattice measured 5.15 s and ran past
// the HTTP bridge's 5 s main-thread wait (HTTP 500). The first block pins the
// helper; the census pins that the production provider actually uses it.
module tests.unit.viewport_probe_sampling_test;

import std.array  : appender;
import std.file   : readText;
import std.format : format;
import std.path   : buildPath, dirName;
import std.string : indexOf;
import std.algorithm : count;
import std.exception : enforce;

import tests.unit.census_symbols : blankNonCode;
import viewport_probe_sampling : ProbePoint, ProbeReadRect, parseProbePoints,
    probeReadRect, putProbePoints;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// A synthetic W x H framebuffer: every GL pixel (x, glY) has a distinct colour.
private ubyte[4] texel(int x, int glY) {
    return [cast(ubyte)(x & 0xff), cast(ubyte)(glY & 0xff),
            cast(ubyte)((x >> 8) | ((glY >> 8) << 4)), 0xa5];
}

private struct FakeReader {
    int W, H;
    int calls;
    ProbeReadRect last;
    void read(int x, int y, int w, int h, ubyte[] rgba) {
        ++calls;
        last = ProbeReadRect(x, y, w, h);
        assert(x >= 0 && y >= 0 && x + w <= W && y + h <= H,
            format("readback rect %s leaves the %dx%d target", last, W, H));
        assert(rgba.length == cast(size_t)w * h * 4, "reader buffer size");
        foreach (r; 0 .. h) foreach (c; 0 .. w) {
            const t = texel(x + c, y + r);
            rgba[(r * w + c) * 4 .. (r * w + c) * 4 + 4] = t[];
        }
    }
}

// What the per-point loop produced for the same request: one entry per
// well-formed spec, colour of GL pixel (x, H-1-y).
private string perPointOracle(const(ProbePoint)[] pts, int H) {
    auto b = appender!string;
    b.put(`"points":[`);
    foreach (i, p; pts) {
        if (i) b.put(",");
        if (!p.inside) {
            b.put(format(`{"x":%d,"y":%d,"error":"outside the cell"}`, p.x, p.y));
            continue;
        }
        const t = texel(p.x, H - 1 - p.y);
        b.put(format(`{"x":%d,"y":%d,"r":%d,"g":%d,"b":%d,"a":%d}`,
                     p.x, p.y, t[0], t[1], t[2], t[3]));
    }
    b.put("]");
    return b.data;
}

unittest // a 3000-point lattice is ONE read, and every sample is the right pixel
{
    enum W = 650, H = 544;
    auto q = appender!string;
    foreach (j; 0 .. 50) foreach (i; 0 .. 60)
        q.put(format("%d,%d;", 145 + i * 6, 122 + j * 6));
    const pts = parseProbePoints(q.data, W, H);
    assert(pts.length == 3000, format("lattice population %d, expected 3000", pts.length));

    FakeReader r = FakeReader(W, H);
    auto buf = appender!string;
    putProbePoints(buf, q.data, W, H, &r.read);
    assert(r.calls == 1,
        format("a 3000-point probe issued %d framebuffer reads; the contract is one", r.calls));
    // The bounding rect of the lattice, GL space: x 145..499, y rows H-1-416 .. H-1-122.
    assert(r.last == ProbeReadRect(145, H - 1 - (122 + 49 * 6), 355, 295),
        format("readback rect %s", r.last));
    assert(buf.data == perPointOracle(pts, H),
        "one-read sampling changed a sample's colour or the response shape");
}

unittest // corners, outside points and malformed specs keep the old response
{
    enum W = 40, H = 30;
    const req = "0,0; 39,29 ;40,0;-1,5;7;a,b;;12,3";
    const pts = parseProbePoints(req, W, H);
    assert(pts.length == 5, format("well-formed population %d, expected 5", pts.length));
    assert(pts[0].inside && pts[1].inside && !pts[2].inside && !pts[3].inside && pts[4].inside);

    FakeReader r = FakeReader(W, H);
    auto buf = appender!string;
    putProbePoints(buf, req, W, H, &r.read);
    assert(r.calls == 1, format("reads %d, expected 1", r.calls));
    assert(r.last == ProbeReadRect(0, 0, W, H), format("corner rect %s", r.last));
    assert(buf.data == perPointOracle(pts, H), buf.data);
}

unittest // no inside point: no read at all
{
    FakeReader r = FakeReader(10, 10);
    auto buf = appender!string;
    putProbePoints(buf, "", 10, 10, &r.read);
    putProbePoints(buf, "11,2;-3,4", 10, 10, &r.read);
    assert(r.calls == 0, format("reads %d for a request with no inside point", r.calls));
    assert(buf.data == `"points":[]"points":[{"x":11,"y":2,"error":"outside the cell"},`
                     ~ `{"x":-3,"y":4,"error":"outside the cell"}]`, buf.data);
}

// Census: the PRODUCTION provider samples through putProbePoints and has no
// per-point read left. The cells above drive the helper with a fake reader;
// rewiring app's provider back to a per-point loop would leave them green, so
// this reads the provider's own text (the event_delivery_owner_test shape).
unittest
{
    const code = blankNonCode(readText(
        buildPath(repoRoot, "source", "http_providers.d")));
    const marker = "setViewportProbeProvider(";
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    const begin = i;
    size_t depth;
    string body_;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) { body_ = code[begin .. i + 1]; break; }
    }
    enforce(body_.length, "unterminated viewport probe provider body");

    assert(body_.count("putProbePoints(") == 1,
        "the viewport probe provider no longer samples points through putProbePoints");
    // Exactly two reads: the one inside putProbePoints' reader and the
    // whole-buffer hash. A third is a per-point read coming back.
    const reads = body_.count("glReadPixels(");
    assert(reads == 2, format(
        "the viewport probe provider has %d glReadPixels calls; expected 2 "
        ~ "(the one-rect point reader + the hash)", reads));
}
